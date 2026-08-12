import SwiftUI
import VoxboardShared
import WidgetKit

// MARK: - MetaSettingsView

/// App-level customization, preferences, upgrade, about metadata, and debug tools.
struct MetaSettingsView: View {
    let persistentRecorder: PersistentRecorder
    let captureToolbarPreferences: CaptureToolbarPreferences

    @Environment(UsageTracker.self) private var usageTracker
    @Environment(StoreManager.self) private var storeManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.openURL) private var openURL

    @State private var showPaywall = false
    @State private var showDebugLog = false
#if os(iOS)
    @State private var showMailCompose = false
#endif
    @State private var hapticsEnabled: Bool = AppConstants.hapticsEnabled
    @State private var liveActivityMonitorEnabled: Bool = AppConstants.liveActivityMonitorEnabled
    @State private var lockScreenQuickRecordEnabled: Bool = AppConstants.lockScreenQuickRecordEnabled

    var body: some View {
        ZStack {
            Geist.Palette.background200.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        upgradeSection
                        GeistDivider()
                        activitySection
                        GeistDivider()
                        recordingQueueSection
                        GeistDivider()
                        customizationSection
                        GeistDivider()
                        keyboardSection
                            .id("settings-keyboard")
                        GeistDivider()
                        lockScreenSection
                        GeistDivider()
                        aboutSection
                            .id("settings-about")
                        GeistDivider()
                        feedbackSection
                        GeistDivider()
                        debugSection
                    }
                }
                #if DEBUG
                .task {
                    await Task.yield()
                    switch RootDestination.localizationScreenshotStory {
                    case "06-privacy-local": proxy.scrollTo("settings-about", anchor: .center)
                    case "07-keyboard": proxy.scrollTo("settings-keyboard", anchor: .center)
                    default: break
                    }
                }
                #endif
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(Geist.heading(.headline))
                    .foregroundColor(Geist.text)
            }
        }
        .toolbarBackground(Geist.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showPaywall) {
            PaywallView(context: .settings)
                .environment(usageTracker)
                .environment(storeManager)
        }
        .sheet(isPresented: $showDebugLog) {
            SettingsDebugLogView()
        }
        // Settings can be opened before StoreKit finishes its launch sync.
        // Refresh here so existing owners always get the Family upgrade offer.
        .task { await storeManager.prepareForPurchases() }
#if os(iOS)
        .sheet(isPresented: $showMailCompose) {
            MailComposeView()
        }
#endif
    }

    // MARK: - Section header

    private func sectionHeader(_ number: String, _ title: LocalizedStringKey) -> some View {
        HStack {
            GeistSectionLabel(number: number, title: title)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .background(Geist.bg)
    }

    // MARK: - Upgrade Section

    private var upgradeSection: some View {
        VStack(spacing: 0) {
            sectionHeader("—", "Vox.md Unlimited")
            GeistDivider()

            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accessTitle)
                            .font(Geist.label())
                            .foregroundColor(Geist.text)
                        Text(accessDetail)
                            .font(Geist.caption())
                            .foregroundColor(Geist.muted)
                    }
                    Spacer()
                    if usageTracker.hasUnlocked {
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(Geist.text)
                                .frame(width: 6, height: 6)
                            Text(usageTracker.hasFamilyAccess
                                 ? String(localized: "Family")
                                 : String(localized: "Purchased"))
                                .font(Geist.caption())
                                .foregroundColor(Geist.text)
                        }
                    } else if let price = storeManager.displayPrice {
                        Text("From \(price)")
                            .font(Geist.label(.headline))
                            .foregroundColor(Geist.text)
                    } else {
                        Text("Checking price…")
                            .font(Geist.caption())
                            .foregroundColor(Geist.muted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                if !usageTracker.hasFamilyAccess {
                    Button(action: { showPaywall = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: usageTracker.hasUnlocked ? "person.3.fill" : "lock.open.fill")
                                .font(.system(.subheadline))
                            if usageTracker.accessLevel == .individual,
                               let price = storeManager.familyUpgradeDisplayPrice {
                                Text("Upgrade to Family — \(price)")
                            } else if usageTracker.accessLevel == .individual {
                                Text("Upgrade to Family")
                            } else {
                                Text("View Lifetime Options")
                            }
                        }
                    }
                    .accessibilityIdentifier(
                        usageTracker.accessLevel == .individual
                            ? "settings.familyUpgradeButton"
                            : "settings.lifetimeOptionsButton"
                    )
                    .buttonStyle(GeistButtonStyle(variant: .primary))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                } else {
                    Spacer().frame(height: 1)
                }
            }
            .background(Geist.bg)
        }
    }

    private var accessTitle: LocalizedStringKey {
        switch usageTracker.accessLevel {
        case .free: "Unlock Unlimited"
        case .individual: "Individual Unlimited"
        case .family: "Family Unlimited"
        }
    }

    private var accessDetail: String {
        switch usageTracker.accessLevel {
        case .free:
            String(
                format: String(localized: "%.1f / 15 min · %d / 10 captures used"),
                usageTracker.minutesUsed,
                usageTracker.successfulCapturesUsed
            )
        case .individual:
            String(localized: "Lifetime access — upgrade to share with family")
        case .family:
            String(localized: "Lifetime access with Apple Family Sharing")
        }
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        VStack(spacing: 0) {
            sectionHeader("01", "Activity")
            GeistDivider()

            settingsNavigationRow(
                "Stats",
                description: "Recordings, recording time, and Capture activity",
                systemImage: "chart.bar.xaxis"
            ) {
                StatsView()
            }
        }
    }

    // MARK: - Recording Queue Section

    private var recordingQueueSection: some View {
        VStack(spacing: 0) {
            sectionHeader("02", "Recording Queue")
            GeistDivider()

            settingsNavigationRow(
                "Manage Recordings",
                description: "Process, retry, share, retain, or delete queued audio",
                systemImage: "waveform.badge.clock"
            ) {
                RecordingQueueView(
                    queue: persistentRecorder.recordingQueue,
                    recoveryPresets: CapturePresetStore.loadFlows()
                ) { job, delivery in
                    await persistentRecorder.recordingQueue.retry(
                        job,
                        modelID: modelManager.selectedModelId,
                        fallbackModelID: modelManager.preferredFallbackModelID,
                        replaceFallbackModelID: true,
                        language: modelManager.selectedLanguage,
                        delivery: delivery
                    )
                }
            }

            GeistDivider()

            RecordingQueuePreferencesView()
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Geist.bg)
        }
    }

    // MARK: - Customization Section

    private var customizationSection: some View {
        VStack(spacing: 0) {
            sectionHeader("03", "Customization")
            GeistDivider()

            settingsNavigationRow(
                "Models",
                description: "Transcription engines, model downloads, and language",
                systemImage: "cpu"
            ) {
                ModelTabView()
            }

            GeistDivider()

            settingsNavigationRow(
                "Capture Presets",
                description: "Processing, formatting, metadata, and destinations",
                systemImage: "slider.horizontal.3"
            ) {
                CapturePresetSettingsView()
            }

            GeistDivider()

            settingsNavigationRow(
                "Capture Bar",
                description: "Choose, reorder, and hide quick actions",
                systemImage: "rectangle.3.group"
            ) {
                CaptureToolbarSettingsView(preferences: captureToolbarPreferences)
            }
        }
    }

    private func settingsNavigationRow<Destination: View>(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(.body, weight: .medium))
                    .foregroundColor(Geist.text)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    Text(description)
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(Geist.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Geist.bg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Keyboard Section

    private var keyboardSection: some View {
        VStack(spacing: 0) {
            sectionHeader("04", "Keyboard")
            GeistDivider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Haptic Feedback")
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    Text("Vibrate on key press. Requires Allow Full Access.")
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                }
                Spacer()
                Toggle("", isOn: $hapticsEnabled)
                    .labelsHidden()
                    .tint(Geist.muted)
                    .onChange(of: hapticsEnabled) { _, val in
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.hapticsEnabledKey)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Geist.bg)
        }
    }

    // MARK: - Lock Screen Section

    private var lockScreenSection: some View {
        VStack(spacing: 0) {
            sectionHeader("05", "Lock Screen")
            GeistDivider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Activity Monitor")
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    Text("Show Vox.md status and Record/Stop controls on the Lock Screen and Dynamic Island while listening.")
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                }
                Spacer()
                Toggle("", isOn: $liveActivityMonitorEnabled)
                    .labelsHidden()
                    .tint(Geist.muted)
                    .onChange(of: liveActivityMonitorEnabled) { _, val in
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.liveActivityMonitorEnabledKey)
                        if val {
                            if persistentRecorder.isListening {
                                LiveActivityController.shared.startIfNeeded()
                            }
                        } else {
                            LiveActivityController.shared.end()
                        }
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Geist.bg)

            GeistDivider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lock Screen Record Button")
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    Text("Allow the Quick Record widget/control to open Vox.md and immediately start recording.")
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                }
                Spacer()
                Toggle("", isOn: $lockScreenQuickRecordEnabled)
                    .labelsHidden()
                    .tint(Geist.muted)
                    .onChange(of: lockScreenQuickRecordEnabled) { _, val in
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.lockScreenQuickRecordEnabledKey)
                        WidgetCenter.shared.reloadTimelines(ofKind: "VoxboardRecordWidget")
                        if #available(iOS 18.0, *) {
                            ControlCenter.shared.reloadControls(ofKind: "VoxboardRecordControl")
                        }
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Geist.bg)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 0) {
            sectionHeader("06", "About")
            GeistDivider()

            var rows: [(String, String)] = [
                (String(localized: "Default transcription"), String(localized: "Apple Speech when available")),
                (String(localized: "Optional Whisper engine"), "whisper.cpp"),
                (String(localized: "Optional Parakeet engine"), "FluidAudio (CoreML)"),
                (String(localized: "Processing"), String(localized: "On-device")),
                (String(localized: "Privacy"), String(localized: "Voice/text stay local")),
                (String(localized: "Version"), appVersionString),
            ]
            let _ = { // build Apple Intelligence row lazily, gated by availability
                if #available(iOS 26, *) {
                    let status = FoundationModelsBackend.isAvailable
                        ? String(localized: "Available")
                        : String(localized: "Unavailable")
                    rows.append((String(localized: "Apple Intelligence"), status))
                }
            }()

            ForEach(rows, id: \.0) { key, val in
                HStack {
                    Text(key)
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                    Spacer()
                    Text(val)
                        .font(Geist.caption())
                        .foregroundColor(Geist.text)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Geist.bg)
                GeistDivider()
            }
        }
    }

    // MARK: - Feedback Section

    private var feedbackSection: some View {
        VStack(spacing: 0) {
            sectionHeader("07", "Feedback")
            GeistDivider()

            Button(action: openDiscord) {
                HStack {
                    Text("Join Our Discord")
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    Spacer()
                    Text("→")
                        .font(Geist.label())
                        .foregroundColor(Geist.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Geist.bg)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Join our Discord")
            .accessibilityHint("Opens the Vox.md Discord community in your browser")

            GeistDivider()

            Button(action: sendFeedback) {
                HStack {
                    Text("Send Feedback")
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    Spacer()
                    Text("→")
                        .font(Geist.label())
                        .foregroundColor(Geist.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Geist.bg)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send Feedback")
            .accessibilityHint("Opens an email draft to contact support with app diagnostics")
        }
    }

    private func openDiscord() {
        guard let url = URL(string: "https://discord.gg/RaQYS4t6gn") else { return }
        openURL(url)
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        VStack(spacing: 0) {
            sectionHeader("08", "Debug")
            GeistDivider()

            Button {
                showDebugLog = true
            } label: {
                HStack {
                    Text("View Debug Log")
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    Spacer()
                    Text("→")
                        .font(Geist.label())
                        .foregroundColor(Geist.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Geist.bg)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func sendFeedback() {
        let payload = FeedbackHelper.makePayload()

#if os(iOS)
        if FeedbackHelper.canSendMail {
            showMailCompose = true
            return
        }
#endif

        guard let url = FeedbackHelper.mailtoURL(payload: payload) else { return }
        openURL(url)
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - Debug Log Viewer

struct SettingsDebugLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Geist.Palette.background100.ignoresSafeArea()
                ScrollView {
                    Text(logText.isEmpty ? String(localized: "(empty)") : logText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Geist.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Debug Log")
                        .font(Geist.heading(.headline))
                        .foregroundColor(Geist.text)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear Log") {
                        KeyboardDebugLog.shared.clear()
                        logText = String(localized: "(cleared)")
                    }
                    .font(Geist.label())
                    .foregroundColor(Geist.error)
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            logText = KeyboardDebugLog.shared.read()
                        } label: {
                            Text("↺")
                                .font(Geist.label(.title3))
                                .foregroundColor(Geist.muted)
                        }
                        .buttonStyle(.plain)
                        Button {
                            UIPasteboard.general.string = logText
                        } label: {
                            Text("Copy Log")
                                .font(Geist.label())
                                .foregroundColor(Geist.muted)
                        }
                        .buttonStyle(.plain)
                        Button("Done") { dismiss() }
                            .font(Geist.label())
                            .foregroundColor(Geist.muted)
                            .buttonStyle(.plain)
                    }
                }
            }
            .toolbarBackground(Geist.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear { logText = KeyboardDebugLog.shared.read() }
    }
}
