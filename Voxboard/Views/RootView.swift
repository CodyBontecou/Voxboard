import SwiftUI
import VoxboardShared

// MARK: - Tab Enum

/// The four top-level destinations in the app.
private enum Tab: Hashable, CaseIterable {
    case listen, model, files, settings

    var label: String {
        switch self {
        case .listen:   return "Listen"
        case .model:    return "Model"
        case .files:    return "Files"
        case .settings: return "Settings"
        }
    }

    var inactiveSymbol: String {
        switch self {
        case .listen:   return "mic"
        case .model:    return "cpu"
        case .files:    return "folder"
        case .settings: return "gearshape"
        }
    }

    var activeSymbol: String {
        switch self {
        case .listen:   return "mic.fill"
        case .model:    return "cpu.fill"
        case .files:    return "folder.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var accessibilityIdentifier: String { "tab_\(label.lowercased())" }

    var accessibilityHint: String {
        switch self {
        case .listen:   return "Record and transcribe audio in real time"
        case .model:    return "Download and select Whisper or Parakeet AI models"
        case .files:    return "Configure automatic transcript file export"
        case .settings: return "App preferences, upgrade, about, and debug"
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
    }

    // MARK: Compact — TabView

    private var compactLayout: some View {
        TabView(selection: $selectedTab) {
            // 1 ── Listen
            NavigationStack {
                HomeView(
                    persistentRecorder: persistentRecorder,
                    pendingKeyboardLaunch: $pendingKeyboardLaunch,
                    pendingWidgetRecord: $pendingWidgetRecord,
                    isEmbeddedInTabBar: true
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

            // 3 ── Files
            NavigationStack {
                FilesTabView()
            }
            .tabItem {
                Image(systemName: selectedTab == .files
                    ? Tab.files.activeSymbol
                    : Tab.files.inactiveSymbol)
                Text(Tab.files.label)
            }
            .tag(Tab.files)
            .accessibilityIdentifier(Tab.files.accessibilityIdentifier)
            .accessibilityHint(Tab.files.accessibilityHint)

            // 4 ── Settings
            NavigationStack {
                MetaSettingsView()
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
            .navigationTitle("VOXBOARD")
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        } detail: {
            switch sidebarTab ?? .listen {
            case .listen:
                HomeView(
                    persistentRecorder: persistentRecorder,
                    pendingKeyboardLaunch: $pendingKeyboardLaunch,
                    pendingWidgetRecord: $pendingWidgetRecord,
                    isEmbeddedInTabBar: true
                )
            case .model:
                ModelTabView()
            case .files:
                FilesTabView()
            case .settings:
                MetaSettingsView()
            }
        }
    }
}
