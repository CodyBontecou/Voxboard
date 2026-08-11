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
    @State private var quickCaptureViewModel: QuickCaptureViewModel
    @State private var windowCoordinator: MacWindowCoordinator
    #if DEBUG
    private static var localizationScreenshotWindow: NSWindow?
    #endif
    @AppStorage(MacAppVisibilityMode.storageKey, store: AppConstants.sharedDefaults)
    private var visibilityModeRaw = MacAppVisibilityMode.dockAndMenuBar.rawValue

    init() {
        Geist.registerBundledFonts()
        let modelManager = ModelManager()
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

        let captureRequestProcessor = CapturePresetRequestProcessor(
            textProcessor: enricher.map(EnrichedCapturePresetTextProcessor.init(enricher:))
        )
        let quickCaptureViewModel = QuickCaptureViewModel(
            defaultCaptureSource: .mac,
            requestProcessor: captureRequestProcessor
        )
        let windowCoordinator = MacWindowCoordinator()
        let recorder = MacRecorder(
            transcriptStore: store,
            usageTracker: usage,
            transcriptEnricher: enricher,
            captureDraftEventHandler: { [weak quickCaptureViewModel] event in
                guard let quickCaptureViewModel else { return false }
                switch event {
                case .audio(let url):
                    return await quickCaptureViewModel.stageRecordedAudio(at: url) != nil
                case .transcript(let text):
                    return await quickCaptureViewModel.appendRecordedTranscript(text)
                case .liveTranscript(let sessionID, let finalizedText, let volatileText):
                    await quickCaptureViewModel.updateLiveRecordedTranscript(
                        sessionID: sessionID,
                        finalizedText: finalizedText,
                        volatileText: volatileText
                    )
                    return true
                case .cancelLiveTranscript:
                    await quickCaptureViewModel.cancelLiveRecordedTranscript()
                    return true
                }
            },
            liveTranscriptInvalidationHandler: { [weak quickCaptureViewModel] sessionID in
                quickCaptureViewModel?.invalidateLiveRecordedTranscriptSession(sessionID)
            },
            pendingCaptureRetryHandler: { [weak quickCaptureViewModel] in
                await quickCaptureViewModel?.processPendingInbox()
            }
        )

        _modelManager = State(initialValue: modelManager)
        _transcriptStore = State(initialValue: store)
        _usageTracker = State(initialValue: usage)
        _storeManager = State(initialValue: storeManager)
        _recorder = State(initialValue: recorder)
        _quickCaptureViewModel = State(initialValue: quickCaptureViewModel)
        _windowCoordinator = State(initialValue: windowCoordinator)

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--localization-screenshot") {
            DispatchQueue.main.async {
                let root = MacLocalizationScreenshotRoot(
                    recorder: recorder,
                    quickCaptureViewModel: quickCaptureViewModel,
                    windowCoordinator: windowCoordinator
                )
                .environment(modelManager)
                .environment(store)
                .environment(usage)
                .environment(storeManager)
                .preferredColorScheme(.light)

                let controller = NSHostingController(rootView: root)
                let window = NSWindow(contentViewController: controller)
                window.title = "Vox.md"
                window.setContentSize(NSSize(width: 1180, height: 760))
                window.center()
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                Self.localizationScreenshotWindow = window
            }
        }
        #endif
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
            MacRootView(
                recorder: recorder,
                quickCaptureViewModel: quickCaptureViewModel,
                windowCoordinator: windowCoordinator
            )
                .environment(modelManager)
                .environment(transcriptStore)
                .environment(usageTracker)
                .environment(storeManager)
                .onAppear {
                    appDelegate.configureURLHandler(handleURL)
                    appDelegate.configureLifecycleHandlers(
                        didBecomeActive: { [weak quickCaptureViewModel, weak windowCoordinator] in
                            if let quickCaptureViewModel, let windowCoordinator {
                                Self.consumePendingQuickCaptureOpenIfNeeded(
                                    quickCaptureViewModel: quickCaptureViewModel,
                                    windowCoordinator: windowCoordinator
                                )
                            }
                            await quickCaptureViewModel?.retryFailedInbox()
                        },
                        flushDraft: { [weak quickCaptureViewModel, weak recorder, weak windowCoordinator] in
                            if recorder?.isRecording == true
                                || recorder?.isTranscribing == true
                                || recorder?.isExporting == true {
                                recorder?.lastError = String(localized: "Wait for the current recording or Capture export to finish before quitting.")
                                windowCoordinator?.showMain(.showCapture)
                                return false
                            }
                            return await quickCaptureViewModel?.flushDraftForTermination() ?? false
                        },
                        reopen: { [weak windowCoordinator] in
                            windowCoordinator?.showMain(.showCapture)
                        }
                    )
                    storeManager.start()
                    transcriptStore.reload()
                    usageTracker.reload()
                    configureGlobalHotKeys()
                    Self.consumePendingQuickCaptureOpenIfNeeded(
                        quickCaptureViewModel: quickCaptureViewModel,
                        windowCoordinator: windowCoordinator
                    )
                    Task {
                        await storeManager.syncCurrentEntitlements()
                        usageTracker.reload()
                        await quickCaptureViewModel.processPendingInbox()
                    }
                }
                .onChange(of: visibilityModeRaw) { _, _ in
                    visibilityMode.apply()
                }
                .onChange(of: usageTracker.hasUnlocked) { _, hasUnlocked in
                    guard hasUnlocked else { return }
                    Task { await quickCaptureViewModel.processPendingInbox() }
                }
        }
        .handlesExternalEvents(matching: ["capture", "capture-request", "listen"])
        .commands {
            CommandMenu("Capture") {
                Button("Show Capture") {
                    windowCoordinator.showMain(.showCapture)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Show History") {
                    windowCoordinator.showHistory()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button(recorder.isRecording
                       ? String(localized: "Stop + Transcribe")
                       : String(localized: "Start Recording")) {
                    Self.handleGlobalHotKey(
                        recorder: recorder,
                        modelManager: modelManager,
                        usageTracker: usageTracker,
                        windowCoordinator: windowCoordinator
                    )
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(recorder.isTranscribing || recorder.isExporting)

                Button("Add Files to Capture…") {
                    windowCoordinator.showMain(.chooseFiles)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Clear Capture Draft") {
                    Task { await quickCaptureViewModel.clearDraft() }
                }
                .disabled(!quickCaptureViewModel.draft.hasCaptureContent)
            }

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

        Window("Capture History", id: "history") {
            NavigationStack {
                MacHistoryView(viewModel: quickCaptureViewModel)
            }
            .background(MacSceneWindowRegistrar(kind: .history, coordinator: windowCoordinator))
            .environment(transcriptStore)
            .environment(usageTracker)
            .environment(storeManager)
            .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 860, height: 680)

        Settings {
            NavigationStack {
                MacSettingsView(recorder: recorder)
            }
            .environment(modelManager)
            .environment(transcriptStore)
            .environment(usageTracker)
            .environment(storeManager)
            .frame(minWidth: 760, minHeight: 640)
        }

        MenuBarExtra(isInserted: menuBarVisibilityBinding) {
            MacMenuBarMenu(recorder: recorder, windowCoordinator: windowCoordinator)
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
        if recorder.isTranscribing || recorder.isExporting { return "waveform.circle.fill" }
        return "mic.circle"
    }

    private var menuBarStatusText: String {
        if recorder.isRecording { return String(localized: "Vox.md is recording") }
        if recorder.isTranscribing { return String(localized: "Vox.md is transcribing") }
        if recorder.isExporting { return String(localized: "Vox.md is finishing the Capture export") }
        return "Vox.md"
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == AppConstants.urlScheme else { return }
        switch url.host {
        case "capture", "capture-request":
            windowCoordinator.showMain(.showCapture)
            do {
                let action = try CaptureDeepLinkParser().parse(url)
                Task { await quickCaptureViewModel.handleDeepLink(action) }
            } catch {
                quickCaptureViewModel.errorMessage = error.localizedDescription
            }
        case "listen":
            windowCoordinator.showMain(.showCapture)
        default:
            break
        }
    }

    @MainActor
    private static func consumePendingQuickCaptureOpenIfNeeded(
        quickCaptureViewModel: QuickCaptureViewModel,
        windowCoordinator: MacWindowCoordinator
    ) {
        guard AppConstants.sharedDefaults?.bool(
            forKey: AppConstants.pendingQuickCaptureOpenKey
        ) == true else { return }

        AppConstants.sharedDefaults?.set(false, forKey: AppConstants.pendingQuickCaptureOpenKey)
        if let rawSource = AppConstants.sharedDefaults?.string(
            forKey: AppConstants.pendingQuickCaptureSourceKey
        ), let source = CaptureSource(rawValue: rawSource) {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureSourceKey)
            quickCaptureViewModel.requestCaptureSource(source)
        }
        if let voxID = AppConstants.sharedDefaults?.string(
            forKey: AppConstants.pendingQuickCaptureVoxIdKey
        ) {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureVoxIdKey)
            quickCaptureViewModel.requestVox(voxID)
        }
        if let rawInput = AppConstants.sharedDefaults?.string(
            forKey: AppConstants.pendingQuickCaptureInputKey
        ), let input = CaptureRequestedInput(rawValue: rawInput) {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureInputKey)
            quickCaptureViewModel.requestedInput = input
        }
        windowCoordinator.showMain(.showCapture)
    }

    private func configureGlobalHotKeys() {
        let recorder = recorder
        let modelManager = modelManager
        let usageTracker = usageTracker
        let windowCoordinator = windowCoordinator
        MacGlobalHotKeyCenter.shared.configure { target in
            let flowID: String?
            let completionMode: MacRecordingCompletionMode?
            switch target {
            case .transcriptionOnly:
                flowID = nil
                completionMode = .transcriptionOnly
            case .selectedPreset:
                flowID = nil
                completionMode = nil
            case .preset(let presetID):
                guard CapturePresetStore.loadFlows().contains(where: {
                    $0.id == presetID && $0.isEnabled
                }) else {
                    NSSound.beep()
                    return
                }
                flowID = presetID
                completionMode = nil
            }
            Self.handleGlobalHotKey(
                recorder: recorder,
                modelManager: modelManager,
                usageTracker: usageTracker,
                windowCoordinator: windowCoordinator,
                flowID: flowID,
                completionMode: completionMode
            )
        }
    }

    @MainActor
    private static func handleGlobalHotKey(
        recorder: MacRecorder,
        modelManager: ModelManager,
        usageTracker: UsageTracker,
        windowCoordinator: MacWindowCoordinator,
        flowID requestedFlowID: String? = nil,
        completionMode: MacRecordingCompletionMode? = nil
    ) {
        guard !recorder.isTranscribing, !recorder.isExporting else {
            NSSound.beep()
            return
        }

        let flowId = requestedFlowID ?? CapturePresetStore.selectedFlowId()
        if recorder.isRecording {
            recorder.stopAndTranscribe(modelManager: modelManager, flowId: flowId)
            return
        }

        guard !usageTracker.isAtLimit else {
            recorder.needsUnlock = true
            windowCoordinator.showMain(.showCapture)
            return
        }

        Task { @MainActor in
            let granted = await AudioRecorder.requestMicrophonePermission()
            guard granted else {
                recorder.lastError = String(localized: "Could not access the microphone. Check macOS Privacy & Security settings.")
                windowCoordinator.showMain(.showCapture)
                return
            }

            recorder.startRecording(
                modelManager: modelManager,
                flowId: flowId,
                completionMode: completionMode
            )
            if !recorder.isRecording, recorder.lastError != nil {
                windowCoordinator.showMain(.showCapture)
            }
        }
    }
}

enum MacMainWindowRequest: Equatable {
    case showCapture
    case chooseFiles
}

enum MacSceneWindowKind {
    case main(token: String)
    case history
}

/// Routes commands to the intended SwiftUI scene instead of guessing from
/// `NSApplication.windows`, where Settings, History, and sheets can all become
/// main windows.
@MainActor
final class MacWindowCoordinator {
    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }

    private var openWindowAction: OpenWindowAction?
    private var mainWindows: [String: WeakWindow] = [:]
    private var historyWindow: WeakWindow?
    private var pendingUnassignedMainRequest: MacMainWindowRequest?
    private var pendingMainRequests: [String: MacMainWindowRequest] = [:]
    private var readyMainTokens = Set<String>()
    private var readyCaptureTokens = Set<String>()

    func configure(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    func register(window: NSWindow, kind: MacSceneWindowKind) {
        switch kind {
        case .main(let token):
            mainWindows[token] = WeakWindow(window)
            if let request = pendingUnassignedMainRequest {
                pendingUnassignedMainRequest = nil
                pendingMainRequests[token] = request
                focus(window)
                if readyMainTokens.contains(token) {
                    route(request, to: token)
                }
            }
        case .history:
            historyWindow = WeakWindow(window)
        }
    }

    func showMain(_ request: MacMainWindowRequest) {
        MacAppVisibilityMode.current.apply()
        pruneClosedWindows()
        if let (token, window) = preferredMainWindow() {
            focus(window)
            route(request, to: token)
        } else {
            pendingUnassignedMainRequest = request
            openWindowAction?(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func mainRootReady(token: String) {
        readyMainTokens.insert(token)
        if let request = pendingMainRequests[token] {
            route(request, to: token)
        }
    }

    func mainRootNotReady(token: String) {
        readyMainTokens.remove(token)
        readyCaptureTokens.remove(token)
    }

    func captureWorkspaceReady(token: String) {
        readyCaptureTokens.insert(token)
        guard readyMainTokens.contains(token),
              pendingMainRequests[token] == .chooseFiles else { return }
        pendingMainRequests[token] = nil
        NotificationCenter.default.post(name: .macChooseCaptureFiles, object: token)
    }

    func captureWorkspaceNotReady(token: String) {
        readyCaptureTokens.remove(token)
    }

    func showHistory() {
        MacAppVisibilityMode.current.apply()
        if let window = historyWindow?.value,
           window.isVisible || window.isMiniaturized {
            focus(window)
        } else {
            openWindowAction?(id: "history")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func preferredMainWindow() -> (String, NSWindow)? {
        if let keyWindow = NSApplication.shared.keyWindow,
           let entry = mainWindows.first(where: { $0.value.value === keyWindow }) {
            return (entry.key, keyWindow)
        }
        for (token, reference) in mainWindows {
            if let window = reference.value,
               window.isVisible || window.isMiniaturized {
                return (token, window)
            }
        }
        return nil
    }

    private func pruneClosedWindows() {
        mainWindows = mainWindows.filter { _, reference in
            guard let window = reference.value else { return false }
            return window.isVisible || window.isMiniaturized
        }
        let liveTokens = Set(mainWindows.keys)
        readyMainTokens.formIntersection(liveTokens)
        readyCaptureTokens.formIntersection(liveTokens)
        pendingMainRequests = pendingMainRequests.filter { liveTokens.contains($0.key) }
        if historyWindow?.value == nil {
            historyWindow = nil
        }
    }

    private func focus(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func route(_ request: MacMainWindowRequest, to token: String) {
        pendingMainRequests[token] = request
        guard readyMainTokens.contains(token) else { return }

        NotificationCenter.default.post(name: .macShowCapture, object: token)
        switch request {
        case .showCapture:
            pendingMainRequests[token] = nil
        case .chooseFiles:
            // If Capture is already mounted, its receiver is ready now. When
            // switching from another destination, workspace readiness will
            // acknowledge the pending request without a timing heuristic.
            if readyCaptureTokens.contains(token) {
                pendingMainRequests[token] = nil
                NotificationCenter.default.post(name: .macChooseCaptureFiles, object: token)
            }
        }
    }
}

struct MacSceneWindowRegistrar: NSViewRepresentable {
    let kind: MacSceneWindowKind
    let coordinator: MacWindowCoordinator

    func makeNSView(context: Context) -> WindowProbeView {
        WindowProbeView { window in
            coordinator.register(window: window, kind: kind)
        }
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.onWindow = { window in
            coordinator.register(window: window, kind: kind)
        }
        if let window = nsView.window {
            coordinator.register(window: window, kind: kind)
        }
    }

    final class WindowProbeView: NSView {
        var onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
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
        case .dockAndMenuBar: return String(localized: "Dock + Menu Bar")
        case .menuBarOnly: return String(localized: "Menu Bar Only")
        case .dockOnly: return String(localized: "Dock Only")
        case .hidden: return String(localized: "Hidden")
        }
    }

    var summary: String {
        switch self {
        case .dockAndMenuBar: return String(localized: "Dock icon, Cmd-Tab, and menu bar")
        case .menuBarOnly: return String(localized: "Menu bar only — hidden from Dock and Cmd-Tab")
        case .dockOnly: return String(localized: "Dock icon and Cmd-Tab — no menu bar")
        case .hidden: return String(localized: "Invisible — reopen from Spotlight or Finder")
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
    private var openURLHandler: ((URL) -> Void)?
    private var pendingOpenURLs: [URL] = []
    private var didBecomeActiveHandler: (@MainActor () async -> Void)?
    private var flushDraftHandler: (@MainActor () async -> Bool)?
    private var reopenHandler: (@MainActor () -> Void)?
    private var isAwaitingTerminationReply = false

    @MainActor
    func configureURLHandler(_ handler: @escaping (URL) -> Void) {
        openURLHandler = handler
        let pending = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for url in pending { handler(url) }
    }

    @MainActor
    func configureLifecycleHandlers(
        didBecomeActive: @escaping @MainActor () async -> Void,
        flushDraft: @escaping @MainActor () async -> Bool,
        reopen: @escaping @MainActor () -> Void
    ) {
        didBecomeActiveHandler = didBecomeActive
        flushDraftHandler = flushDraft
        reopenHandler = reopen
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--localization-screenshot") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            scheduleLocalizationScreenshotIfRequested()
            return
        }
        #endif
        MacAppVisibilityMode.current.applyImmediately()
        MacKeyboardHintCenter.shared.start()
    }

    #if DEBUG
    private func scheduleLocalizationScreenshotIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--localization-screenshot-output"),
              arguments.indices.contains(index + 1) else { return }
        let destination = URL(fileURLWithPath: arguments[index + 1])

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let candidates = NSApp.windows.filter { $0.contentView != nil }
            guard let window = candidates.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }),
                  let view = window.contentView else { return }

            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            view.layoutSubtreeIfNeeded()

            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        MacKeyboardHintCenter.shared.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let didBecomeActiveHandler else { return }
        Task { await didBecomeActiveHandler() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let openURLHandler else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        for url in urls { openURLHandler(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            reopenHandler?()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flushDraftHandler else { return .terminateNow }
        guard !isAwaitingTerminationReply else { return .terminateLater }
        isAwaitingTerminationReply = true
        Task {
            let saved = await flushDraftHandler()
            isAwaitingTerminationReply = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

enum MacHotKeyTarget: Hashable, Identifiable {
    case transcriptionOnly
    case selectedPreset
    case preset(String)

    var id: String {
        switch self {
        case .transcriptionOnly: "transcription-only"
        case .selectedPreset: "selected-preset"
        case .preset(let presetID): "preset:\(presetID)"
        }
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

    func conflicts(with other: MacHotKeyShortcut) -> Bool {
        keyCode == other.keyCode && modifierFlags == other.modifierFlags
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
    /// Retained for compatibility with existing installations that configured
    /// the original single start/stop shortcut.
    static let storageKey = "macGlobalHotKeyShortcut"
    static let transcriptionOnlyStorageKey = "macTranscriptionOnlyHotKeyShortcut"
    static let presetStorageKey = "macCapturePresetHotKeyShortcuts"

    static func load(for target: MacHotKeyTarget = .selectedPreset) -> MacHotKeyShortcut? {
        switch target {
        case .transcriptionOnly:
            guard let encoded = AppConstants.sharedDefaults?.string(forKey: transcriptionOnlyStorageKey) else { return nil }
            return decode(encoded)
        case .selectedPreset:
            guard let encoded = AppConstants.sharedDefaults?.string(forKey: storageKey) else { return nil }
            return decode(encoded)
        case .preset(let presetID):
            return loadPresetShortcuts()[presetID]
        }
    }

    static func save(_ shortcut: MacHotKeyShortcut, for target: MacHotKeyTarget = .selectedPreset) {
        switch target {
        case .transcriptionOnly:
            guard let encoded = encode(shortcut) else { return }
            AppConstants.sharedDefaults?.set(encoded, forKey: transcriptionOnlyStorageKey)
        case .selectedPreset:
            guard let encoded = encode(shortcut) else { return }
            AppConstants.sharedDefaults?.set(encoded, forKey: storageKey)
        case .preset(let presetID):
            var shortcuts = loadPresetShortcuts()
            shortcuts[presetID] = shortcut
            savePresetShortcuts(shortcuts)
        }
    }

    static func clear(_ target: MacHotKeyTarget = .selectedPreset) {
        switch target {
        case .transcriptionOnly:
            AppConstants.sharedDefaults?.removeObject(forKey: transcriptionOnlyStorageKey)
        case .selectedPreset:
            AppConstants.sharedDefaults?.removeObject(forKey: storageKey)
        case .preset(let presetID):
            var shortcuts = loadPresetShortcuts()
            shortcuts.removeValue(forKey: presetID)
            savePresetShortcuts(shortcuts)
        }
    }

    static func configuredBindings() -> [(target: MacHotKeyTarget, shortcut: MacHotKeyShortcut)] {
        var bindings: [(MacHotKeyTarget, MacHotKeyShortcut)] = []
        if let shortcut = load(for: .transcriptionOnly) {
            bindings.append((.transcriptionOnly, shortcut))
        }
        if let shortcut = load() {
            bindings.append((.selectedPreset, shortcut))
        }
        bindings.append(contentsOf: loadPresetShortcuts()
            .sorted(by: { $0.key < $1.key })
            .map { (.preset($0.key), $0.value) })
        return bindings
    }

    static func conflictingTarget(
        for shortcut: MacHotKeyShortcut,
        excluding excludedTarget: MacHotKeyTarget,
        activePresetIDs: Set<String>
    ) -> MacHotKeyTarget? {
        configuredBindings().first(where: { binding in
            guard binding.target != excludedTarget,
                  binding.shortcut.conflicts(with: shortcut) else { return false }
            switch binding.target {
            case .transcriptionOnly, .selectedPreset:
                return true
            case .preset(let presetID):
                return activePresetIDs.contains(presetID)
            }
        })?.target
    }

    static func decode(_ encoded: String) -> MacHotKeyShortcut? {
        guard let data = encoded.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MacHotKeyShortcut.self, from: data)
    }

    static func encode(_ shortcut: MacHotKeyShortcut) -> String? {
        guard let data = try? JSONEncoder().encode(shortcut) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func loadPresetShortcuts() -> [String: MacHotKeyShortcut] {
        guard let encoded = AppConstants.sharedDefaults?.string(forKey: presetStorageKey),
              let data = encoded.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: MacHotKeyShortcut].self, from: data)) ?? [:]
    }

    private static func savePresetShortcuts(_ shortcuts: [String: MacHotKeyShortcut]) {
        guard !shortcuts.isEmpty else {
            AppConstants.sharedDefaults?.removeObject(forKey: presetStorageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(shortcuts),
              let encoded = String(data: data, encoding: .utf8) else { return }
        AppConstants.sharedDefaults?.set(encoded, forKey: presetStorageKey)
    }
}

private let macHotKeySignature: OSType = 0x564F5848 // VOXH

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
          hotKeyID.signature == 0x564F5848 else {
        return noErr
    }

    let pressedHotKeyID = hotKeyID.id
    Task { @MainActor in
        MacGlobalHotKeyCenter.shared.handleHotKeyPressed(id: pressedHotKeyID)
    }
    return noErr
}

@MainActor
final class MacGlobalHotKeyCenter {
    static let shared = MacGlobalHotKeyCenter()

    private var action: ((MacHotKeyTarget) -> Void)?
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var targetsByHotKeyID: [UInt32: MacHotKeyTarget] = [:]

    private(set) var lastRegistrationError: String?

    func configure(action: @escaping (MacHotKeyTarget) -> Void) {
        self.action = action
        installEventHandlerIfNeeded()
        reloadRegistration()
    }

    func reloadRegistration() {
        unregisterHotKeys()
        lastRegistrationError = nil

        let enabledPresetIDs = Set(
            CapturePresetStore.loadFlows()
                .filter(\.isEnabled)
                .map(\.id)
        )
        let bindings = MacHotKeyStore.configuredBindings().filter { binding in
            switch binding.target {
            case .transcriptionOnly, .selectedPreset:
                true
            case .preset(let presetID):
                enabledPresetIDs.contains(presetID)
            }
        }
        var errors: [String] = []

        for (index, binding) in bindings.enumerated() {
            let modifiers = binding.shortcut.carbonModifiers
            guard modifiers != 0 else { continue }

            let id = UInt32(index + 1)
            let hotKeyID = EventHotKeyID(signature: macHotKeySignature, id: id)
            var newHotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.shortcut.keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &newHotKeyRef
            )

            if status == noErr, let newHotKeyRef {
                hotKeyRefs.append(newHotKeyRef)
                targetsByHotKeyID[id] = binding.target
                KeyboardDebugLog.shared.log(
                    "[MacHotKey] Registered \(binding.target.id): \(binding.shortcut.displayString)"
                )
            } else {
                errors.append(String(localized: "Could not register \(binding.shortcut.displayString). Try a different shortcut. (OSStatus \(status))"))
                KeyboardDebugLog.shared.log(
                    "[MacHotKey] ❌ RegisterEventHotKey failed for \(binding.target.id): \(status)"
                )
            }
        }
        lastRegistrationError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func handleHotKeyPressed(id: UInt32) {
        guard let target = targetsByHotKeyID[id] else { return }
        KeyboardDebugLog.shared.log("[MacHotKey] Hotkey pressed for \(target.id)")
        action?(target)
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
            lastRegistrationError = String(localized: "Could not install Vox.md hotkey listener. (OSStatus \(status))")
            KeyboardDebugLog.shared.log("[MacHotKey] ❌ InstallEventHandler failed: \(status)")
        }
    }

    private func unregisterHotKeys() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        targetsByHotKeyID.removeAll()
    }
}

private struct MacMenuBarMenu: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(TranscriptStore.self) private var transcriptStore

    @Bindable var recorder: MacRecorder
    let windowCoordinator: MacWindowCoordinator
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
            .disabled(recorder.isTranscribing || recorder.isExporting)
        }

        Button {
            chooseImport()
        } label: {
            Label("Import Audio…", systemImage: "waveform")
        }
        .disabled(recorder.isRecording || recorder.isTranscribing || recorder.isExporting || usageTracker.isAtLimit)

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
        .disabled(recorder.isRecording || recorder.isTranscribing || recorder.isExporting)

        Button {
            windowCoordinator.showMain(.showCapture)
        } label: {
            Label("Show Capture", systemImage: "square.and.pencil")
        }
        .keyboardShortcut("0")

        Button {
            windowCoordinator.showHistory()
        } label: {
            Label("Show History", systemImage: "clock.arrow.circlepath")
        }

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
        if recorder.isRecording { return String(localized: "Vox.md — Recording") }
        if recorder.isTranscribing { return String(localized: "Vox.md — Transcribing") }
        if recorder.isExporting { return String(localized: "Vox.md — Finishing Export") }
        return String(localized: "Vox.md — Ready")
    }

    private var recordButtonTitle: String {
        if usageTracker.isAtLimit { return String(localized: "Unlock to Record") }
        if recorder.isTranscribing { return String(localized: "Transcribing…") }
        if recorder.isExporting { return String(localized: "Finishing Export…") }
        return String(localized: "Start Recording")
    }

    private func beginRecording() {
        guard !usageTracker.isAtLimit else {
            recorder.needsUnlock = true
            windowCoordinator.showMain(.showCapture)
            return
        }

        Task { @MainActor in
            let granted = await AudioRecorder.requestMicrophonePermission()
            guard granted else {
                recorder.lastError = String(localized: "Could not access the microphone. Check macOS Privacy & Security settings.")
                windowCoordinator.showMain(.showCapture)
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
