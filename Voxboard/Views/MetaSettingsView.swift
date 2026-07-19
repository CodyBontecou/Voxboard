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

            ScrollView {
                VStack(spacing: 0) {
                    upgradeSection
                    GeistDivider()
                    customizationSection
                    GeistDivider()
                    keyboardSection
                    GeistDivider()
                    lockScreenSection
                    GeistDivider()
                    aboutSection
                    GeistDivider()
                    feedbackSection
                    GeistDivider()
                    debugSection
                }
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

            if usageTracker.hasUnlocked {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unlimited Unlocked")
                            .font(Geist.label())
                            .foregroundColor(Geist.text)
                        Text("Lifetime access — no limits")
                            .font(Geist.caption())
                            .foregroundColor(Geist.muted)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Geist.text)
                            .frame(width: 6, height: 6)
                        Text("Purchased")
                            .font(Geist.caption())
                            .foregroundColor(Geist.text)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Geist.bg)
            } else {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unlock Unlimited")
                                .font(Geist.label())
                                .foregroundColor(Geist.text)
                            Text(String(
                                format: String(localized: "%.1f / 15 min · %d / 10 captures used"),
                                usageTracker.minutesUsed,
                                usageTracker.successfulCapturesUsed
                            ))
                                .font(Geist.caption())
                                .foregroundColor(Geist.muted)
                        }
                        Spacer()
                        Text(storeManager.displayPrice)
                            .font(Geist.label(.headline))
                            .foregroundColor(Geist.text)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    Button(action: { showPaywall = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.open.fill")
                                .font(.system(.subheadline))
                            Text("View Upgrade Options")
                        }
                    }
                    .buttonStyle(GeistButtonStyle(variant: .primary))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .background(Geist.bg)
            }
        }
    }

    // MARK: - Customization Section

    private var customizationSection: some View {
        VStack(spacing: 0) {
            sectionHeader("01", "Customization")
            GeistDivider()

            customizationRow(
                "Models",
                description: "Transcription engines, model downloads, and language",
                systemImage: "cpu"
            ) {
                ModelTabView()
            }

            GeistDivider()

            customizationRow(
                "Capture Presets",
                description: "Processing, formatting, metadata, and destinations",
                systemImage: "slider.horizontal.3"
            ) {
                CapturePresetSettingsView()
            }

            GeistDivider()

            customizationRow(
                "Capture Bar",
                description: "Choose, reorder, and hide quick actions",
                systemImage: "rectangle.3.group"
            ) {
                CaptureToolbarSettingsView(preferences: captureToolbarPreferences)
            }
        }
    }

    private func customizationRow<Destination: View>(
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
            sectionHeader("02", "Keyboard")
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
            sectionHeader("03", "Lock Screen")
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
            sectionHeader("04", "About")
            GeistDivider()

            var rows: [(String, String)] = [
                ("Default transcription", "Apple Speech when available"),
                ("Optional Whisper engine", "whisper.cpp"),
                ("Optional Parakeet engine", "FluidAudio (CoreML)"),
                ("Processing", "On-device"),
                ("Privacy", "Voice/text stay local"),
                ("Version", appVersionString),
            ]
            let _ = { // build Apple Intelligence row lazily, gated by availability
                if #available(iOS 26, *) {
                    let status = FoundationModelsBackend.isAvailable
                        ? "Available"
                        : "Unavailable"
                    rows.append(("Apple Intelligence", status))
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
            sectionHeader("05", "Feedback")
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
            sectionHeader("06", "Debug")
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
