import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoxboardShared

/// Main screen — brutal black/white aesthetic matching imghost.isolated.tech.
struct HomeView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(TranscriptStore.self) private var transcriptStore
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(StoreManager.self) private var storeManager

    @Bindable var persistentRecorder: PersistentRecorder
    @Binding var pendingKeyboardLaunch: Bool
    @Binding var pendingWidgetRecord: Bool

    @State private var showHistory = false
    @State private var showPaywall = false
    @State private var paywallContext: OnboardingAnalyticsPaywallContext = .limit
    @State private var micPermissionGranted = false
    @State private var keyboardLaunchPhase: KeyboardLaunchPhase? = nil
    @State private var fileExportToast: FileExportToast?
    @State private var flows: [RecordingFlow] = RecordingFlowStore.loadFlows()
    @State private var selectedFlowId: String = RecordingFlowStore.selectedFlowId()
    @State private var showAudioImporter = false

    @AppStorage("discordPromoDismissed") private var discordPromoDismissed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Brutal.bg.ignoresSafeArea()

            BrutalGridBackground()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                if !discordPromoDismissed {
                    discordBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                topBar
                BrutalDivider()
                Spacer()
                centerContent
                Spacer()
                BrutalDivider()
                bottomArea
            }

            if let toast = fileExportToast {
                FileExportToastView(fileName: toast.url.lastPathComponent) {
                    openExportedFileInFiles(toast.url)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 104)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }

            if let phase = keyboardLaunchPhase {
                KeyboardLaunchOverlay(phase: phase)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: keyboardLaunchPhase)
        .animation(.easeInOut(duration: 0.2), value: fileExportToast)
        .animation(.easeInOut(duration: 0.25), value: discordPromoDismissed)
        .gesture(
            DragGesture(minimumDistance: 40, coordinateSpace: .local)
                .onEnded { val in
                    if val.translation.height < -40,
                       abs(val.translation.height) > abs(val.translation.width) {
                        showHistory = true
                    }
                }
        )
        .sheet(isPresented: $showHistory) {
            HistoryView().environment(transcriptStore)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(context: paywallContext)
                .environment(usageTracker)
                .environment(storeManager)
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            handleAudioImport(result)
        }
        .onAppear {
            reloadFlows()
        }
        .task {
            let granted = await AudioRecorder.requestMicrophonePermission()
            micPermissionGranted = granted
            OnboardingAnalyticsClient.shared.trackMicrophonePermissionCompleted(
                status: granted ? .granted : .denied,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
        }
        .onChange(of: pendingKeyboardLaunch) { _, isPending in
            if isPending {
                pendingKeyboardLaunch = false
                handleKeyboardLaunch()
            }
        }
        .onChange(of: pendingWidgetRecord) { _, isPending in
            if isPending {
                pendingWidgetRecord = false
                handleWidgetRecord()
            }
        }
        .onChange(of: persistentRecorder.needsUnlock) { _, needs in
            if needs {
                persistentRecorder.needsUnlock = false
                usageTracker.reload()
                if usageTracker.isAtLimit {
                    presentPaywall(context: .limit)
                }
            }
        }
        .onChange(of: persistentRecorder.lastFileExportEvent) { _, event in
            guard let event else { return }
            fileExportToast = FileExportToast(url: event.url)
        }
        .task(id: fileExportToast?.id) {
            guard fileExportToast != nil else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { fileExportToast = nil }
        }
    }

    // MARK: - Discord Banner

    private var discordBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: openDiscord) {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(.callout))
                            .foregroundColor(Brutal.text)
                            .frame(width: 28, height: 28)
                            .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("JOIN THE COMMUNITY")
                                .font(Brutal.label(.footnote))
                                .foregroundColor(Brutal.text)
                            Text("Chat with us on Discord")
                                .font(Brutal.caption())
                                .foregroundColor(Brutal.muted)
                        }

                        Spacer(minLength: 8)

                        Text("JOIN")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Join the Discord community.")

                Button(action: { discordPromoDismissed = true }) {
                    Image(systemName: "xmark")
                        .font(.system(.footnote, weight: .medium))
                        .foregroundColor(Brutal.muted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Discord banner.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Brutal.surface2)

            BrutalDivider()
        }
    }

    private func openDiscord() {
        guard let url = URL(string: "https://discord.gg/RaQYS4t6gn") else { return }
        openURL(url)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack {
                BrutalStatusBadge(
                    label: statusBadgeLabel,
                    isActive: statusBadgeIsActive
                )
                Spacer()
                Text("VOXBOARD")
                    .font(Brutal.label(.headline))
                    .foregroundColor(Brutal.text)
                Spacer()
                // Settings lives in its own tab — keep top bar balanced with a spacer
                Color.clear.frame(width: 34, height: 34)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            flowSelectorBar

            // Usage bar — only shown to free-tier users
            if !usageTracker.hasUnlocked {
                usageMeterBar
            }
        }
    }

    private var usageMeterBar: some View {
        Button(action: { presentPaywall(context: .usageMeter) }) {
            HStack(spacing: 10) {
                // Progress track
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Brutal.surface).frame(height: 2)
                        Rectangle()
                            .fill(usageTracker.isAtLimit ? Brutal.error : Brutal.text)
                            .frame(width: geo.size.width * usageTracker.fractionUsed, height: 2)
                    }
                }
                .frame(height: 2)

                // Label
                if usageTracker.isAtLimit {
                    Text("LIMIT REACHED — UNLOCK →")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.error)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text(String(format: String(localized: "%.1f / 15 MIN FREE"), usageTracker.minutesUsed))
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Brutal.surface.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private var flowSelectorBar: some View {
        HStack(spacing: 10) {
            Text("VOX")
                .font(Brutal.caption())
                .foregroundColor(Brutal.muted)
            Menu {
                ForEach(enabledFlows) { flow in
                    Button(flow.displayName) {
                        selectFlow(flow)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedFlow.symbolName)
                        .font(.system(.caption, weight: .semibold))
                    Text(selectedFlow.displayName.uppercased())
                        .font(Brutal.caption())
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(Brutal.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Brutal.surface.opacity(0.35))
    }

    private var enabledFlows: [RecordingFlow] {
        let enabled = flows.filter(\.isEnabled)
        return enabled.isEmpty ? RecordingFlowStore.defaultFlows : enabled
    }

    private var selectedFlow: RecordingFlow {
        enabledFlows.first(where: { $0.id == selectedFlowId }) ?? enabledFlows[0]
    }

    private var statusBadgeLabel: LocalizedStringKey {
        if persistentRecorder.isSegmentActive { return "Recording" }
        if persistentRecorder.isTranscribing { return "Processing" }
        if persistentRecorder.isListening { return "Listening" }
        return "Off"
    }

    private var statusBadgeIsActive: Bool {
        persistentRecorder.isListening || persistentRecorder.isSegmentActive || persistentRecorder.isTranscribing
    }

    // MARK: - Center Content

    @ViewBuilder
    private var centerContent: some View {
        if !micPermissionGranted {
            noMicView
        } else if persistentRecorder.isSegmentActive {
            recordingView
        } else if persistentRecorder.isTranscribing {
            transcribingView
        } else if let error = persistentRecorder.lastError {
            errorView(error)
        } else if let result = persistentRecorder.lastTranscriptionResult {
            resultView(result)
        } else if persistentRecorder.isListening {
            listeningIdleView
        } else {
            standbyView
        }
    }

    // MARK: Standby

    private var standbyView: some View {
        VStack(spacing: 28) {
            BrutalSectionLabel(number: "01", title: "Status")
            VStack(spacing: 8) {
                Text("STANDBY.")
                    .font(Brutal.display(60))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text("Tap START RECORDING below")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: No Mic

    private var noMicView: some View {
        VStack(spacing: 20) {
            BrutalSectionLabel(number: "01", title: "Status")
            VStack(spacing: 8) {
                Text("NO MIC.")
                    .font(Brutal.display(52))
                    .foregroundColor(Brutal.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text("Enable microphone access in Settings")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
            }
        }
        .padding(.horizontal, 24)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            BrutalSectionLabel(number: "01", title: "Status")
            Text("ERROR.")
                .font(Brutal.display(52))
                .foregroundColor(Brutal.error)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
            Text(message)
                .font(Brutal.body())
                .foregroundColor(Brutal.muted)
                .multilineTextAlignment(.center)
            Button("DISMISS") {
                persistentRecorder.lastError = nil
            }
            .buttonStyle(BrutalButtonStyle(variant: .secondary))
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 24)
    }

    // MARK: Listening states

    @ViewBuilder
    private var listeningContent: some View {
        if persistentRecorder.isSegmentActive {
            recordingView
        } else if persistentRecorder.isTranscribing {
            transcribingView
        } else if let result = persistentRecorder.lastTranscriptionResult {
            resultView(result)
        } else {
            listeningIdleView
        }
    }

    private var listeningIdleView: some View {
        VStack(spacing: 28) {
            BrutalSectionLabel(number: "01", title: "Status")
            VStack(spacing: 16) {
                Text("LISTENING.")
                    .font(Brutal.display(52))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                IdleWaveformView()
                Text("Keyboard mic ready in any app")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
            }
            Button(action: { startRecording() }) {
                HStack(spacing: 8) {
                    Image(systemName: usageTracker.isAtLimit ? "lock.fill" : "mic.fill")
                        .font(.system(.footnote))
                    Text(usageTracker.isAtLimit ? "UNLOCK TO RECORD" : "RECORD IN APP")
                }
            }
            .buttonStyle(BrutalButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .secondary))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    private var recordingView: some View {
        VStack(spacing: 24) {
            BrutalSectionLabel(number: "01", title: "Status")
            VStack(spacing: 10) {
                Text("RECORDING.")
                    .font(Brutal.display(48))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(formatDuration(persistentRecorder.segmentDuration))
                    .font(Brutal.display(54))
                    .foregroundColor(Brutal.text)
                    .monospacedDigit()
            }
            Text("Return to your app — recording continues")
                .font(Brutal.body())
                .foregroundColor(Brutal.muted)
                .multilineTextAlignment(.center)
            Button(action: { persistentRecorder.stopInAppSegment() }) {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill").font(.system(.footnote))
                    Text("STOP + TRANSCRIBE")
                }
            }
            .buttonStyle(BrutalButtonStyle(variant: .destructive))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    private var transcribingView: some View {
        VStack(spacing: 24) {
            BrutalSectionLabel(number: "01", title: "Status")
            TranscribingDotsView()
            Text("Processing audio on-device")
                .font(Brutal.body())
                .foregroundColor(Brutal.muted)
        }
        .padding(.horizontal, 24)
    }

    private func resultView(_ result: String) -> some View {
        VStack(spacing: 24) {
            BrutalSectionLabel(number: "01", title: "Status")
            Text("DONE.")
                .font(Brutal.display(52))
                .foregroundColor(Brutal.text)
                .lineLimit(1)
                .minimumScaleFactor(0.3)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("TRANSCRIPT")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.muted)
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = result
                        persistentRecorder.lastTranscriptionResult = nil
                    }) {
                        Text("COPY + CLEAR")
                            .font(Brutal.label())
                            .foregroundColor(Brutal.text)
                    }
                    .buttonStyle(.plain)
                }
                Text(result)
                    .font(Brutal.body())
                    .foregroundColor(Brutal.text)
                    .lineSpacing(4)
            }
            .padding(16)
            .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))

            Button(action: { startRecording() }) {
                HStack(spacing: 8) {
                    Image(systemName: usageTracker.isAtLimit ? "lock.fill" : "mic.fill")
                        .font(.system(.footnote))
                    Text(usageTracker.isAtLimit ? "UNLOCK TO RECORD" : "RECORD AGAIN")
                }
            }
            .buttonStyle(BrutalButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .secondary))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Bottom Area

    private var bottomArea: some View {
        VStack(spacing: 0) {
            Button(action: { showHistory = true }) {
                HStack(spacing: 5) {
                    Text("↑")
                    Text("HISTORY")
                }
                .font(Brutal.label())
                .foregroundColor(Brutal.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            BrutalDivider()

            if !persistentRecorder.isSegmentActive && !persistentRecorder.isTranscribing {
                HStack(spacing: 12) {
                    Group {
                        if persistentRecorder.isListening {
                            Button(action: { stopPersistentListening() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "stop.fill").font(.system(.footnote))
                                    Text("STOP LISTENING")
                                }
                            }
                            .buttonStyle(BrutalButtonStyle(variant: .secondary))
                        } else {
                            Button(action: { startRecording() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: usageTracker.isAtLimit ? "lock.fill" : "mic.fill").font(.system(.footnote))
                                    Text(usageTracker.isAtLimit ? "UNLOCK TO RECORD" : "START RECORDING")
                                }
                            }
                            .buttonStyle(BrutalButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .primary))
                        }
                    }

                    Button(action: { showAudioImporter = true }) {
                        Image(systemName: "waveform")
                            .font(.system(.callout, weight: .semibold))
                            .foregroundColor(Brutal.text)
                            .frame(width: 52, height: 52)
                            .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Import audio")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
    }

    // MARK: - Actions

    private func reloadFlows() {
        flows = RecordingFlowStore.loadFlows()
        selectedFlowId = RecordingFlowStore.selectedFlowId()
    }

    private func selectFlow(_ flow: RecordingFlow) {
        RecordingFlowStore.selectFlow(id: flow.id)
        selectedFlowId = flow.id
    }

    private func handleAudioImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            persistentRecorder.importAudioFile(from: url)
        case .failure(let error):
            persistentRecorder.lastError = error.localizedDescription
        }
    }

    private func presentPaywall(context: OnboardingAnalyticsPaywallContext) {
        paywallContext = context
        showPaywall = true
    }

    private func startRecording() {
        if usageTracker.isAtLimit {
            presentPaywall(context: .recording)
            return
        }
        persistentRecorder.lastTranscriptionResult = nil
        persistentRecorder.startOneShotInAppSegment()
    }

    private func stopPersistentListening() {
        persistentRecorder.stopListening()
        AppConstants.sharedDefaults?.set(false, forKey: AppConstants.autoListenEnabledKey)
    }

    func handleWidgetRecord() {
        guard AppConstants.lockScreenQuickRecordEnabled else { return }

        let requestedFlowId = AppConstants.sharedDefaults?.string(forKey: AppConstants.pendingWidgetRecordFlowIdKey)
        AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingWidgetRecordFlowIdKey)

        let flowId: String? = requestedFlowId.flatMap { requested in
            guard let flow = RecordingFlowStore.flow(id: requested), flow.isEnabled else { return nil }
            RecordingFlowStore.selectFlow(id: flow.id)
            selectedFlowId = flow.id
            return flow.id
        }

        persistentRecorder.startOneShotInAppSegment(flowId: flowId)
    }

    func handleKeyboardLaunch() {
        keyboardLaunchPhase = .starting
        OnboardingAnalyticsClient.shared.trackKeyboardSetupStarted(
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )
        DispatchQueue.main.async {
            if !persistentRecorder.isListening {
                persistentRecorder.startListening()
            }
            withAnimation {
                keyboardLaunchPhase = persistentRecorder.isListening ? .ready : .error
            }
            if persistentRecorder.isListening {
                OnboardingAnalyticsClient.shared.trackKeyboardSetupCompleted(
                    quotaState: usageTracker.onboardingAnalyticsQuotaState
                )
            }
            // Auto-dismiss the "ready" overlay after 2.5 s so the user knows to
            // return to their app. The error overlay stays until dismissed manually.
            if persistentRecorder.isListening {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation {
                        if keyboardLaunchPhase == .ready { keyboardLaunchPhase = nil }
                    }
                }
            }
        }
    }

    private func openExportedFileInFiles(_ url: URL) {
        fileExportToast = nil

        let didScopeFile = url.startAccessingSecurityScopedResource()
        UIApplication.shared.open(url, options: [:]) { success in
            if didScopeFile { url.stopAccessingSecurityScopedResource() }
            guard !success else { return }

            let folderURL = url.deletingLastPathComponent()
            let didScopeFolder = folderURL.startAccessingSecurityScopedResource()
            UIApplication.shared.open(folderURL, options: [:]) { _ in
                if didScopeFolder { folderURL.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        let t = Int((d * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%d:%02d.%d", m, s, t)
    }
}

private struct FileExportToast: Equatable {
    let id = UUID()
    let url: URL
}

private struct FileExportToastView: View {
    let fileName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(Brutal.text)

                VStack(alignment: .leading, spacing: 3) {
                    Text("SUCCESS")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Text(fileName)
                        .font(Brutal.body())
                        .foregroundColor(Brutal.text)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("OPEN")
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Brutal.surface2)
            .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Keyboard Launch Phase

enum KeyboardLaunchPhase: Equatable {
    case starting, ready, error
}

// MARK: - Keyboard Launch Overlay

private struct KeyboardLaunchOverlay: View {
    let phase: KeyboardLaunchPhase

    var body: some View {
        ZStack {
            Brutal.bg.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()
                phaseIcon
                phaseText
                Spacer()
                Spacer()
            }
            .padding(32)
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch phase {
        case .starting:
            ZStack {
                Rectangle()
                    .fill(Brutal.surface)
                    .frame(width: 80, height: 80)
                    .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Brutal.text)
            }
        case .ready:
            Rectangle()
                .fill(Brutal.surface)
                .frame(width: 80, height: 80)
                .overlay(
                    Text("✓")
                        .font(Brutal.heading(.largeTitle))
                        .foregroundColor(Brutal.text)
                )
                .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
        case .error:
            Rectangle()
                .fill(Brutal.surface)
                .frame(width: 80, height: 80)
                .overlay(
                    Text("!")
                        .font(Brutal.heading(.largeTitle))
                        .foregroundColor(Brutal.error)
                )
                .overlay(Rectangle().stroke(Brutal.error, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var phaseText: some View {
        switch phase {
        case .starting:
            VStack(spacing: 10) {
                Text("STARTING MIC")
                    .font(Brutal.heading(.title2))
                    .foregroundColor(Brutal.text)
                Text("Setting up always-on listening...")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
            }
        case .ready:
            VStack(spacing: 10) {
                Text("READY.")
                    .font(Brutal.heading(.title))
                    .foregroundColor(Brutal.text)
                Text("Return to your app\nand tap Record on the keyboard.")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        case .error:
            VStack(spacing: 10) {
                Text("MIC ERROR.")
                    .font(Brutal.heading(.title))
                    .foregroundColor(Brutal.error)
                Text("Check microphone permissions\nin Settings.")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
    }
}
