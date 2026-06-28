import SwiftUI
import VoxboardShared

// MARK: - Tab Enum

/// The four top-level destinations in the app.
private enum Tab: Hashable, CaseIterable {
    case listen, model, vox, settings

    var label: String {
        switch self {
        case .listen:   return "Listen"
        case .model:    return "Model"
        case .vox:      return "Vox"
        case .settings: return "Settings"
        }
    }

    var inactiveSymbol: String {
        switch self {
        case .listen:   return "mic"
        case .model:    return "cpu"
        case .vox:      return "waveform.circle"
        case .settings: return "gearshape"
        }
    }

    var activeSymbol: String {
        switch self {
        case .listen:   return "mic.fill"
        case .model:    return "cpu.fill"
        case .vox:      return "waveform.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var accessibilityIdentifier: String { "tab_\(label.lowercased())" }

    var accessibilityHint: String {
        switch self {
        case .listen:   return String(localized: "Record and transcribe audio in real time")
        case .model:    return String(localized: "Download and select Whisper or Parakeet AI models")
        case .vox:      return String(localized: "Manage Vox presets for export routing and post-processing")
        case .settings: return String(localized: "App preferences, upgrade, about, and debug")
        }
    }
}

// MARK: - RootView

/// Adaptive root container.
/// • iPhone / compact width → `TabView` with custom-tinted bottom bar
/// • iPad / regular width   → `NavigationSplitView` with a sidebar
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var persistentRecorder: PersistentRecorder
    @Binding var pendingKeyboardLaunch: Bool
    @Binding var pendingWidgetRecord: Bool

    /// Active tab in the compact (iPhone) TabView.
    @State private var selectedTab: Tab = .listen
    /// Selected row in the regular (iPad) sidebar — optional as List requires.
    @State private var sidebarTab: Tab? = .listen

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if pendingWidgetRecord || pendingKeyboardLaunch {
                focusListenTab()
            }
        }
        .onChange(of: pendingWidgetRecord) { _, isPending in
            if isPending {
                focusListenTab()
            }
        }
        .onChange(of: pendingKeyboardLaunch) { _, isPending in
            if isPending {
                focusListenTab()
            }
        }
    }

    // MARK: Compact — TabView

    private var compactLayout: some View {
        TabView(selection: $selectedTab) {
            // 1 ── Listen
            NavigationStack {
                HomeView(
                    persistentRecorder: persistentRecorder,
                    pendingKeyboardLaunch: $pendingKeyboardLaunch,
                    pendingWidgetRecord: $pendingWidgetRecord
                )
            }
            .tabItem {
                Image(systemName: selectedTab == .listen
                    ? Tab.listen.activeSymbol
                    : Tab.listen.inactiveSymbol)
                Text(Tab.listen.label)
            }
            .tag(Tab.listen)
            .accessibilityIdentifier(Tab.listen.accessibilityIdentifier)
            .accessibilityHint(Tab.listen.accessibilityHint)

            // 2 ── Model
            NavigationStack {
                ModelTabView()
            }
            .tabItem {
                Image(systemName: selectedTab == .model
                    ? Tab.model.activeSymbol
                    : Tab.model.inactiveSymbol)
                Text(Tab.model.label)
            }
            .tag(Tab.model)
            .accessibilityIdentifier(Tab.model.accessibilityIdentifier)
            .accessibilityHint(Tab.model.accessibilityHint)

            // 3 ── Vox
            NavigationStack {
                FlowSettingsView()
            }
            .tabItem {
                Image(systemName: selectedTab == .vox
                    ? Tab.vox.activeSymbol
                    : Tab.vox.inactiveSymbol)
                Text(Tab.vox.label)
            }
            .tag(Tab.vox)
            .accessibilityIdentifier(Tab.vox.accessibilityIdentifier)
            .accessibilityHint(Tab.vox.accessibilityHint)

            // 4 ── Settings
            NavigationStack {
                MetaSettingsView(persistentRecorder: persistentRecorder)
            }
            .tabItem {
                Image(systemName: selectedTab == .settings
                    ? Tab.settings.activeSymbol
                    : Tab.settings.inactiveSymbol)
                Text(Tab.settings.label)
            }
            .tag(Tab.settings)
            .accessibilityIdentifier(Tab.settings.accessibilityIdentifier)
            .accessibilityHint(Tab.settings.accessibilityHint)
        }
        // Brutal design tokens: white tint on dark, black tint on light
        .tint(colorScheme == .dark ? Brutal.text : Brutal.bg)
        .toolbarBackground(Brutal.bg, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    // MARK: Regular — NavigationSplitView (iPad)

    private var regularLayout: some View {
        NavigationSplitView {
            // List(selection:) requires Binding<SelectionValue?> on iOS
            List(selection: $sidebarTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Label(tab.label, systemImage: tab.inactiveSymbol)
                        .font(Brutal.label())
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Brutal.bg)
            .navigationTitle("VOX.MD")
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        } detail: {
            switch sidebarTab ?? .listen {
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

    private func focusListenTab() {
        selectedTab = .listen
        sidebarTab = .listen
    }
}
