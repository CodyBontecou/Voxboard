import SwiftUI
import VoxboardShared

// MARK: - App navigation

enum RootDestination: Hashable {
    case capture
    case settings
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
                openSettings: { rootDestination = .settings }
            )
            .navigationDestination(isPresented: settingsIsPresented) {
                MetaSettingsView(persistentRecorder: persistentRecorder)
            }
        }
    }

    private var settingsIsPresented: Binding<Bool> {
        Binding(
            get: { rootDestination == .settings },
            set: { rootDestination = $0 ? .settings : .capture }
        )
    }
}
