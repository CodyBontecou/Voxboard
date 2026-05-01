import SwiftUI
import VoxboardShared

// MARK: - MetaSettingsView

/// Tab 4 — app-level settings: upgrade / paywall, about metadata, and debug tools.
struct MetaSettingsView: View {
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.openURL) private var openURL

    @State private var showPaywall = false
    @State private var showDebugLog = false
#if os(iOS)
    @State private var showMailCompose = false
#endif
    @State private var hapticsEnabled: Bool = AppConstants.hapticsEnabled

    var body: some View {
        ZStack {
            Brutal.surface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    upgradeSection
                    BrutalDivider()
                    keyboardSection
                    BrutalDivider()
                    aboutSection
                    BrutalDivider()
                    feedbackSection
                    BrutalDivider()
                    debugSection
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("SETTINGS")
                    .font(Brutal.label(.headline))
                    .foregroundColor(Brutal.text)
            }
        }
        .toolbarBackground(Brutal.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
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
            BrutalSectionLabel(number: number, title: title)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .background(Brutal.bg)
    }

    // MARK: - Upgrade Section

    private var upgradeSection: some View {
        VStack(spacing: 0) {
            sectionHeader("—", "Voxboard Unlimited")
            BrutalDivider()

            if usageTracker.hasUnlocked {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UNLIMITED UNLOCKED")
                            .font(Brutal.label())
                            .foregroundColor(Brutal.text)
                        Text("Lifetime access — no limits")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Brutal.text)
                            .frame(width: 6, height: 6)
                        Text("PURCHASED")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.text)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brutal.bg)
            } else {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("UNLOCK UNLIMITED")
                                .font(Brutal.label())
                                .foregroundColor(Brutal.text)
                            Text(String(format: String(localized: "%.1f / 15 min free used"), usageTracker.minutesUsed))
                                .font(Brutal.caption())
                                .foregroundColor(Brutal.muted)
                        }
                        Spacer()
                        Text(storeManager.displayPrice)
                            .font(Brutal.label(.headline))
                            .foregroundColor(Brutal.text)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    Button(action: { showPaywall = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.open.fill")
                                .font(.system(.subheadline))
                            Text("VIEW UPGRADE OPTIONS")
                        }
                    }
                    .buttonStyle(BrutalButtonStyle(variant: .primary))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .background(Brutal.bg)
            }
        }
    }

    // MARK: - Keyboard Section

    private var keyboardSection: some View {
        VStack(spacing: 0) {
            sectionHeader("01", "Keyboard")
            BrutalDivider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HAPTIC FEEDBACK")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Text("Vibrate on key press. Requires Allow Full Access.")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                }
                Spacer()
                Toggle("", isOn: $hapticsEnabled)
                    .labelsHidden()
                    .tint(Brutal.muted)
                    .onChange(of: hapticsEnabled) { _, val in
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.hapticsEnabledKey)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Brutal.bg)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 0) {
            sectionHeader("02", "About")
            BrutalDivider()

            var rows: [(String, String)] = [
                ("Whisper engine", "whisper.cpp"),
                ("Parakeet engine", "FluidAudio (CoreML)"),
                ("Processing", "On-device"),
                ("Privacy", "Zero data leaves device"),
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
                    Text(key.uppercased())
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Spacer()
                    Text(val)
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.text)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Brutal.bg)
                BrutalDivider()
            }
        }
    }

    // MARK: - Feedback Section

    private var feedbackSection: some View {
        VStack(spacing: 0) {
            sectionHeader("03", "Feedback")
            BrutalDivider()

            Button(action: openDiscord) {
                HStack {
                    Text("JOIN OUR DISCORD")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Spacer()
                    Text("→")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brutal.bg)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Join our Discord")
            .accessibilityHint("Opens the Voxboard Discord community in your browser")

            BrutalDivider()

            Button(action: sendFeedback) {
                HStack {
                    Text("SEND FEEDBACK")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Spacer()
                    Text("→")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brutal.bg)
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
            sectionHeader("04", "Debug")
            BrutalDivider()

            Button {
                showDebugLog = true
            } label: {
                HStack {
                    Text("VIEW DEBUG LOG")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Spacer()
                    Text("→")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brutal.bg)
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
                Color.black.ignoresSafeArea()
                ScrollView {
                    Text(logText.isEmpty ? String(localized: "(empty)") : logText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Brutal.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("DEBUG LOG")
                        .font(Brutal.label(.headline))
                        .foregroundColor(Brutal.text)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("CLEAR") {
                        KeyboardDebugLog.shared.clear()
                        logText = String(localized: "(cleared)")
                    }
                    .font(Brutal.label())
                    .foregroundColor(Brutal.error)
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            logText = KeyboardDebugLog.shared.read()
                        } label: {
                            Text("↺")
                                .font(Brutal.label(.title3))
                                .foregroundColor(Brutal.muted)
                        }
                        .buttonStyle(.plain)
                        Button {
                            UIPasteboard.general.string = logText
                        } label: {
                            Text("COPY")
                                .font(Brutal.label())
                                .foregroundColor(Brutal.muted)
                        }
                        .buttonStyle(.plain)
                        Button("DONE") { dismiss() }
                            .font(Brutal.label())
                            .foregroundColor(Brutal.muted)
                            .buttonStyle(.plain)
                    }
                }
            }
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { logText = KeyboardDebugLog.shared.read() }
    }
}
