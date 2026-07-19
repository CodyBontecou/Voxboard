import AppKit
import Carbon
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
        Geist.registerBundledFonts()
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
        WindowGroup("Vox.md", id: "main") {
            MacRootView(recorder: recorder)
                .environment(modelManager)
                .environment(transcriptStore)
                .environment(usageTracker)
                .environment(storeManager)
                .onAppear {
                    storeManager.start()
                    transcriptStore.reload()
                    usageTracker.reload()
                    configureGlobalHotKey()
                    Task {
                        await storeManager.syncCurrentEntitlements()
                        usageTracker.reload()
                        await recorder.processPendingCaptureInbox()
                    }
                }
                .onChange(of: visibilityModeRaw) { _, _ in
                    visibilityMode.apply()
                }
                .onChange(of: usageTracker.hasUnlocked) { _, hasUnlocked in
                    guard hasUnlocked else { return }
                    Task { await recorder.processPendingCaptureInbox() }
                }
        }
        .commands {
            CommandMenu("Vox.md") {
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
        if recorder.isRecording { return "Vox.md is recording" }
        if recorder.isTranscribing { return "Vox.md is transcribing" }
        return "Vox.md"
    }

    private func configureGlobalHotKey() {
        let recorder = recorder
        let modelManager = modelManager
        let usageTracker = usageTracker
        MacGlobalHotKeyCenter.shared.configure {
            Self.handleGlobalHotKey(
                recorder: recorder,
                modelManager: modelManager,
                usageTracker: usageTracker
            )
        }
    }

    @MainActor
    private static func handleGlobalHotKey(
        recorder: MacRecorder,
        modelManager: ModelManager,
        usageTracker: UsageTracker
    ) {
        guard !recorder.isTranscribing else {
            NSSound.beep()
            return
        }

        let flowId = CapturePresetStore.selectedFlowId()
        if recorder.isRecording {
            recorder.stopAndTranscribe(modelManager: modelManager, flowId: flowId)
            return
        }

        guard !usageTracker.isAtLimit else {
            recorder.needsUnlock = true
            bringMainWindowForward()
            return
        }

        Task { @MainActor in
            let granted = await AudioRecorder.requestMicrophonePermission()
            guard granted else {
                recorder.lastError = "Could not access the microphone. Check macOS Privacy & Security settings."
                bringMainWindowForward()
                return
            }

            recorder.startRecording(modelManager: modelManager, flowId: flowId)
            if !recorder.isRecording, recorder.lastError != nil {
                bringMainWindowForward()
            }
        }
    }

    @MainActor
    private static func bringMainWindowForward() {
        MacAppVisibilityMode.current.apply()
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
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

struct MacHotKeyShortcut: Codable, Equatable {
    static let allowedModifierFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    private static let requiredModifierFlags: NSEvent.ModifierFlags = [.command, .option, .control]

    let keyCode: UInt32
    let modifierFlagsRawValue: UInt
    let keyEquivalent: String

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.allowedModifierFlags)
        guard !modifiers.intersection(Self.requiredModifierFlags).isEmpty else { return nil }

        let keyName = Self.keyName(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
        guard !keyName.isEmpty else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.modifierFlagsRawValue = modifiers.rawValue
        self.keyEquivalent = keyName
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue).intersection(Self.allowedModifierFlags)
    }

    var carbonModifiers: UInt32 {
        var carbonModifiers: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        return carbonModifiers
    }

    var displayString: String {
        var pieces: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { pieces.append("⌃") }
        if flags.contains(.option) { pieces.append("⌥") }
        if flags.contains(.shift) { pieces.append("⇧") }
        if flags.contains(.command) { pieces.append("⌘") }
        pieces.append(keyEquivalent)
        return pieces.joined()
    }

    private static func keyName(keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 71: return "Clear"
        case 76: return "Enter"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let trimmed = (charactersIgnoringModifiers ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            return trimmed.uppercased()
        }
    }
}

enum MacHotKeyStore {
    static let storageKey = "macGlobalHotKeyShortcut"

    static func load() -> MacHotKeyShortcut? {
        guard let encoded = AppConstants.sharedDefaults?.string(forKey: storageKey) else { return nil }
        return decode(encoded)
    }

    static func save(_ shortcut: MacHotKeyShortcut) {
        guard let encoded = encode(shortcut) else { return }
        AppConstants.sharedDefaults?.set(encoded, forKey: storageKey)
    }

    static func clear() {
        AppConstants.sharedDefaults?.removeObject(forKey: storageKey)
    }

    static func decode(_ encoded: String) -> MacHotKeyShortcut? {
        guard let data = encoded.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MacHotKeyShortcut.self, from: data)
    }

    static func encode(_ shortcut: MacHotKeyShortcut) -> String? {
        guard let data = try? JSONEncoder().encode(shortcut) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private let macHotKeySignature: OSType = 0x564F5848 // VOXH
private let macHotKeyIDValue: UInt32 = 1

nonisolated private func macHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == 0x564F5848,
          hotKeyID.id == 1 else {
        return noErr
    }

    Task { @MainActor in
        MacGlobalHotKeyCenter.shared.handleHotKeyPressed()
    }
    return noErr
}

@MainActor
final class MacGlobalHotKeyCenter {
    static let shared = MacGlobalHotKeyCenter()

    private var action: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    private(set) var lastRegistrationError: String?

    func configure(action: @escaping () -> Void) {
        self.action = action
        installEventHandlerIfNeeded()
        reloadRegistration()
    }

    func reloadRegistration() {
        unregisterHotKey()
        lastRegistrationError = nil

        guard let shortcut = MacHotKeyStore.load() else { return }

        let modifiers = shortcut.carbonModifiers
        guard modifiers != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: macHotKeySignature, id: macHotKeyIDValue)
        var newHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newHotKeyRef
        )

        if status == noErr {
            hotKeyRef = newHotKeyRef
            KeyboardDebugLog.shared.log("[MacHotKey] Registered global hotkey: \(shortcut.displayString)")
        } else {
            lastRegistrationError = "Could not register \(shortcut.displayString). Try a different shortcut. (OSStatus \(status))"
            KeyboardDebugLog.shared.log("[MacHotKey] ❌ RegisterEventHotKey failed: \(status)")
        }
    }

    func handleHotKeyPressed() {
        KeyboardDebugLog.shared.log("[MacHotKey] Hotkey pressed")
        action?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = macHotKeyHandler
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            lastRegistrationError = "Could not install Vox.md hotkey listener. (OSStatus \(status))"
            KeyboardDebugLog.shared.log("[MacHotKey] ❌ InstallEventHandler failed: \(status)")
        }
    }

    private func unregisterHotKey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }
}

private struct MacMenuBarMenu: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(TranscriptStore.self) private var transcriptStore
    @Environment(\.openWindow) private var openWindow

    @Bindable var recorder: MacRecorder
    @AppStorage(CapturePresetStore.selectedFlowIdKey, store: AppConstants.sharedDefaults)
    private var selectedFlowId = CapturePresetStore.generalId

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

        Picker("Capture Preset", selection: $selectedFlowId) {
            ForEach(enabledFlows) { flow in
                Label(flow.displayName, systemImage: iconName(for: flow.symbolName))
                    .tag(flow.id)
            }
        }

        Button {
            showMainWindow()
        } label: {
            Label("Show Vox.md", systemImage: "macwindow")
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

        Button("Quit Vox.md") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var enabledFlows: [CapturePreset] {
        let enabled = CapturePresetStore.loadFlows().filter(\.isEnabled)
        return enabled.isEmpty ? CapturePresetStore.defaultFlows : enabled
    }

    private var statusTitle: String {
        if recorder.isRecording { return "Vox.md — Recording" }
        if recorder.isTranscribing { return "Vox.md — Transcribing" }
        return "Vox.md — Ready"
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
