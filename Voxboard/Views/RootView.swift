import SwiftUI
import VoxboardShared

// MARK: - App navigation

enum AppTab: Hashable, CaseIterable {
    case capture, listen, model, vox, settings

    var label: String {
        switch self {
        case .capture: return "Capture"
        case .listen: return "Listen"
        case .model: return "Model"
        case .vox: return "Vox"
        case .settings: return "Settings"
        }
    }

    var inactiveSymbol: String {
        switch self {
        case .capture: return "square.and.pencil"
        case .listen: return "mic"
        case .model: return "cpu"
        case .vox: return "waveform.circle"
        case .settings: return "gearshape"
        }
    }

    var activeSymbol: String {
        switch self {
        case .capture: return "square.and.pencil"
        case .listen: return "mic.fill"
        case .model: return "cpu.fill"
        case .vox: return "waveform.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var accessibilityIdentifier: String { "tab_\(label.lowercased())" }

    var accessibilityHint: String {
        switch self {
        case .capture: return String(localized: "Capture text, links, and attachments to Markdown")
        case .listen: return String(localized: "Record and transcribe audio in real time")
        case .model: return String(localized: "Download and select Whisper or Parakeet AI models")
        case .vox: return String(localized: "Manage Vox presets for export routing and post-processing")
        case .settings: return String(localized: "App preferences, upgrade, about, and debug")
        }
    }
}

// MARK: - RootView

/// Adaptive root container.
/// • iPhone / compact width → `TabView` with five capture and voice destinations.
/// • iPad / regular width   → `NavigationSplitView` with a sidebar.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Bindable var persistentRecorder: PersistentRecorder
    @Bindable var quickCaptureViewModel: QuickCaptureViewModel
    @Binding var selectedTab: AppTab
    @Binding var pendingKeyboardLaunch: Bool
    @Binding var pendingWidgetRecord: Bool

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .background(Geist.Palette.background100)
        .onAppear {
            if pendingWidgetRecord || pendingKeyboardLaunch {
                focusListenTab()
            }
        }
        .onChange(of: pendingWidgetRecord) { _, isPending in
            if isPending { focusListenTab() }
        }
        .onChange(of: pendingKeyboardLaunch) { _, isPending in
            if isPending { focusListenTab() }
        }
    }

    private var compactLayout: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                QuickCaptureView(
                    viewModel: quickCaptureViewModel,
                    microphoneIsBusy: {
                        persistentRecorder.isListening
                            || persistentRecorder.isSegmentActive
                            || persistentRecorder.isTranscribing
                    }
                )
            }
            .tabItem { tabLabel(.capture) }
            .tag(AppTab.capture)
            .accessibilityIdentifier(AppTab.capture.accessibilityIdentifier)
            .accessibilityHint(AppTab.capture.accessibilityHint)

            NavigationStack {
                HomeView(
                    persistentRecorder: persistentRecorder,
                    pendingKeyboardLaunch: $pendingKeyboardLaunch,
                    pendingWidgetRecord: $pendingWidgetRecord
                )
            }
            .tabItem { tabLabel(.listen) }
            .tag(AppTab.listen)
            .accessibilityIdentifier(AppTab.listen.accessibilityIdentifier)
            .accessibilityHint(AppTab.listen.accessibilityHint)

            NavigationStack {
                ModelTabView()
            }
            .tabItem { tabLabel(.model) }
            .tag(AppTab.model)
            .accessibilityIdentifier(AppTab.model.accessibilityIdentifier)
            .accessibilityHint(AppTab.model.accessibilityHint)

            NavigationStack {
                FlowSettingsView()
            }
            .tabItem { tabLabel(.vox) }
            .tag(AppTab.vox)
            .accessibilityIdentifier(AppTab.vox.accessibilityIdentifier)
            .accessibilityHint(AppTab.vox.accessibilityHint)

            NavigationStack {
                MetaSettingsView(persistentRecorder: persistentRecorder)
            }
            .tabItem { tabLabel(.settings) }
            .tag(AppTab.settings)
            .accessibilityIdentifier(AppTab.settings.accessibilityIdentifier)
            .accessibilityHint(AppTab.settings.accessibilityHint)
        }
        .tint(Geist.Palette.gray1000)
        .toolbarBackground(Geist.Palette.background100, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    @ViewBuilder
    private func tabLabel(_ tab: AppTab) -> some View {
        Image(systemName: selectedTab == tab ? tab.activeSymbol : tab.inactiveSymbol)
        Text(tab.label)
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Label(tab.label, systemImage: tab.inactiveSymbol)
                        .font(Geist.label())
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Geist.Palette.background100)
            .navigationTitle("Vox.md")
            .toolbarBackground(Geist.Palette.background100, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        } detail: {
            switch selectedTab {
            case .capture:
                QuickCaptureView(
                    viewModel: quickCaptureViewModel,
                    microphoneIsBusy: {
                        persistentRecorder.isListening
                            || persistentRecorder.isSegmentActive
                            || persistentRecorder.isTranscribing
                    }
                )
            case .listen:
                HomeView(
                    persistentRecorder: persistentRecorder,
                    pendingKeyboardLaunch: $pendingKeyboardLaunch,
                    pendingWidgetRecord: $pendingWidgetRecord
                )
            case .model:
                ModelTabView()
            case .vox:
                FlowSettingsView()
            case .settings:
                MetaSettingsView(persistentRecorder: persistentRecorder)
            }
        }
    }

    private var sidebarSelection: Binding<AppTab?> {
        Binding(
            get: { selectedTab },
            set: { if let value = $0 { selectedTab = value } }
        )
    }

    private func focusListenTab() {
        selectedTab = .listen
    }
}
