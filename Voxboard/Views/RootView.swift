import SwiftUI
import VoxboardShared

// MARK: - App navigation

enum RootDestination: Hashable {
    case capture
    case history
    case settings
    case models
    case capturePresets
    case appLanguage

    #if DEBUG
    static var localizationScreenshotStory: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--localization-screenshot"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static var localizationScreenshotDestination: RootDestination? {
        switch localizationScreenshotStory {
        case "02-history": .history
        case "03-settings", "06-privacy-local", "07-keyboard", "09-app-language-row": .settings
        case "04-models": .models
        case "05-capture-presets": .capturePresets
        case "08-app-language": .appLanguage
        default: nil
        }
    }
    #endif
}

// MARK: - RootView

/// The capture composer is the app's root. Secondary destinations are opened
/// from its action bar instead of a persistent tab bar or sidebar.
struct RootView: View {
    @Bindable var persistentRecorder: PersistentRecorder
    @Bindable var quickCaptureViewModel: QuickCaptureViewModel
    @Binding var rootDestination: RootDestination
    @Binding var pendingKeyboardLaunch: Bool
    @Binding var pendingWidgetRecord: Bool

    @State private var captureToolbarPreferences = CaptureToolbarPreferences()

    var body: some View {
        captureRoot
            .background(Geist.Palette.background100)
            .onChange(of: pendingWidgetRecord) { _, isPending in
                if isPending { rootDestination = .capture }
            }
            .onChange(of: pendingKeyboardLaunch) { _, isPending in
                if isPending { rootDestination = .capture }
            }
    }

    private var captureRoot: some View {
        NavigationStack {
            QuickCaptureView(
                viewModel: quickCaptureViewModel,
                persistentRecorder: persistentRecorder,
                pendingKeyboardLaunch: $pendingKeyboardLaunch,
                pendingWidgetRecord: $pendingWidgetRecord,
                captureToolbarPreferences: captureToolbarPreferences,
                openSettings: { rootDestination = .settings }
            )
            .navigationDestination(isPresented: secondaryDestinationIsPresented) {
                secondaryDestination
            }
        }
    }

    @ViewBuilder
    private var secondaryDestination: some View {
        switch rootDestination {
        case .capture:
            EmptyView()
        case .history:
            HistoryView(viewModel: quickCaptureViewModel)
        case .settings:
            MetaSettingsView(
                persistentRecorder: persistentRecorder,
                captureToolbarPreferences: captureToolbarPreferences
            )
        case .models:
            ModelTabView()
        case .capturePresets:
            CapturePresetSettingsView()
        case .appLanguage:
            AppLanguageSettingsView()
        }
    }

    private var secondaryDestinationIsPresented: Binding<Bool> {
        Binding(
            get: { rootDestination != .capture },
            set: { if !$0 { rootDestination = .capture } }
        )
    }
}
