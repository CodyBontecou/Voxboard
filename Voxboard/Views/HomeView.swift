import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoxboardShared

/// Main recording screen, built from the vendored Geist design tokens.
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
    @State private var micPermissionGranted = Self.currentMicrophonePermissionGranted()
    @State private var keyboardLaunchPhase: KeyboardLaunchPhase? = nil
    @State private var fileExportToast: FileExportToast?
    @State private var flows: [RecordingFlow] = RecordingFlowStore.loadFlows()
    @State private var selectedFlowId: String = RecordingFlowStore.selectedFlowId()
    @State private var showAudioImporter = false
    @State private var watchRecordingInboxItems: [WatchRecordingInboxItem] = WatchRecordingInbox.shared.load()
    @State private var isProcessingWatchRecordingQueue = false
    @State private var watchRecordingProcessingQueue: [WatchRecordingInboxItem] = []
    @State private var watchRecordingProcessingTotal = 0
    @State private var watchRecordingProcessingIndex = 0

    @AppStorage("discordPromoDismissed") private var discordPromoDismissed = false
    @Environment(\.openURL) private var openURL

    private static func currentMicrophonePermissionGranted() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    var body: some View {
        ZStack {
            Geist.Palette.background200.ignoresSafeArea()

            VStack(spacing: 0) {
                if !discordPromoDismissed {
                    discordBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                topBar
                GeistDivider()
                Spacer(minLength: Geist.Spacing.four)
                centerContent
                    .frame(maxWidth: 560)
                    .geistCard(padding: Geist.Spacing.eight)
                    .padding(.horizontal, Geist.Spacing.four)
                Spacer(minLength: Geist.Spacing.four)
                GeistDivider()
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
            reloadWatchRecordingInbox()
            consumePendingWidgetRecordIfNeeded()
            autoProcessWatchRecordingQueueIfPossible()
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchRecordingInbox.didChangeNotification)) { _ in
            reloadWatchRecordingInbox()
            autoProcessWatchRecordingQueueIfPossible()
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
                consumePendingWidgetRecordIfNeeded()
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
            switch event.result {
            case .success(let url):
                fileExportToast = FileExportToast(url: url)
            case .failure(let message):
                fileExportToast = nil
                persistentRecorder.lastError = "Your transcript was saved locally, but file export failed. \(message)"
            }
        }
        .onChange(of: persistentRecorder.isTranscribing) { _, isTranscribing in
            guard !isTranscribing else { return }
            processNextQueuedWatchRecordingIfNeeded()
            autoProcessWatchRecordingQueueIfPossible()
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
                            .foregroundColor(Geist.text)
                            .frame(width: 28, height: 28)
                            .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Join the Community")
                                .font(Geist.label(.footnote))
                                .foregroundColor(Geist.text)
                            Text("Chat with us on Discord")
                                .font(Geist.caption())
                                .foregroundColor(Geist.muted)
                        }

                        Spacer(minLength: 8)

                        Text("Join Discord")
                            .font(Geist.caption())
                            .foregroundColor(Geist.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Join the Discord community.")

                Button(action: { discordPromoDismissed = true }) {
                    Image(systemName: "xmark")
                        .font(.system(.footnote, weight: .medium))
                        .foregroundColor(Geist.muted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Discord banner.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Geist.surface2)

            GeistDivider()
        }
    }

    private func openDiscord() {
        guard let url = URL(string: "https://discord.gg/RaQYS4t6gn") else { return }
        openURL(url)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.four) {
            HStack(alignment: .top, spacing: Geist.Spacing.four) {
                VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                    Text("Listen")
                        .font(Geist.heading(.title2))
                        .foregroundStyle(Geist.text)
                    Text("Record and transcribe on device")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
                Spacer()
                GeistStatusBadge(
                    label: statusBadgeLabel,
                    isActive: statusBadgeIsActive
                )
            }

            flowSelectorBar

            if !usageTracker.hasUnlocked {
                usageMeterBar
            }
        }
        .padding(.horizontal, Geist.Spacing.four)
        .padding(.vertical, Geist.Spacing.four)
        .background(Geist.Palette.background100)
    }

    private var usageMeterBar: some View {
        Button(action: { presentPaywall(context: .usageMeter) }) {
            HStack(spacing: 10) {
                // Progress track
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Geist.surface).frame(height: 2)
                        Rectangle()
                            .fill(usageTracker.isAtLimit ? Geist.error : Geist.text)
                            .frame(width: geo.size.width * usageTracker.fractionUsed, height: 2)
                    }
                }
                .frame(height: 2)

                // Label
                if usageTracker.isAtLimit {
                    Text("Limit reached · Unlock")
                        .font(Geist.caption())
                        .foregroundColor(Geist.error)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text(String(format: String(localized: "%.1f / 15 min free"), usageTracker.minutesUsed))
                        .font(Geist.mono())
                        .foregroundColor(Geist.muted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Geist.surface.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private var flowSelectorBar: some View {
        HStack(spacing: 10) {
            Text("Vox")
                .font(Geist.caption())
                .foregroundColor(Geist.muted)
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
                    Text(selectedFlow.displayName)
                        .font(Geist.label())
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(Geist.text)
                .padding(.horizontal, Geist.Spacing.three)
                .frame(height: Geist.ControlHeight.medium)
                .background(Geist.Palette.background100)
                .overlay(
                    RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous)
                        .stroke(Geist.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
            }
            Spacer()
        }
        .padding(Geist.Spacing.two)
        .background(Geist.Palette.background200)
        .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
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
        if persistentRecorder.isSegmentActive {
            recordingView
        } else if persistentRecorder.isTranscribing {
            transcribingView
        } else if !watchRecordingInboxItems.isEmpty {
            watchRecordingInboxView
        } else if let error = persistentRecorder.lastError {
            errorView(error)
        } else if let result = persistentRecorder.lastTranscriptionResult {
            resultView(result)
        } else if persistentRecorder.isListening {
            listeningIdleView
        } else if !micPermissionGranted {
            noMicView
        } else {
            standbyView
        }
    }

    // MARK: Standby

    private var standbyView: some View {
        VStack(spacing: Geist.Spacing.six) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Geist.Palette.blue700)
                .frame(width: 64, height: 64)
                .background(Geist.Palette.blue100)
                .clipShape(Circle())
            VStack(spacing: Geist.Spacing.two) {
                Text("Ready to Record")
                    .font(Geist.heading(.largeTitle))
                    .foregroundStyle(Geist.text)
                    .multilineTextAlignment(.center)
                Text("Start a recording or import an audio file.")
                    .font(Geist.body())
                    .foregroundStyle(Geist.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: No Mic

    private var noMicView: some View {
        VStack(spacing: 20) {
            GeistSectionLabel(number: "01", title: "Status")
            VStack(spacing: 8) {
                Text("Microphone Unavailable")
                    .font(Geist.heading(.title))
                    .foregroundColor(Geist.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text("Enable microphone access in Settings to record audio.")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
            }
        }
        .padding(.horizontal, 24)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            GeistSectionLabel(number: "01", title: "Status")
            Text("Recording Error")
                .font(Geist.heading(.title))
                .foregroundColor(Geist.error)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
            Text(message)
                .font(Geist.body())
                .foregroundColor(Geist.muted)
                .multilineTextAlignment(.center)
            Button("Dismiss Error") {
                persistentRecorder.lastError = nil
            }
            .buttonStyle(GeistButtonStyle(variant: .secondary))
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
            GeistSectionLabel(number: "01", title: "Status")
            VStack(spacing: 16) {
                Text("Listening")
                    .font(Geist.heading(.largeTitle))
                    .foregroundColor(Geist.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                IdleWaveformView()
                Text("Keyboard mic ready in any app")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
            }
            Button(action: { startRecording() }) {
                HStack(spacing: 8) {
                    Image(systemName: usageTracker.isAtLimit ? "lock.fill" : "mic.fill")
                        .font(.system(.footnote))
                    Text(usageTracker.isAtLimit ? "Unlock to Record" : "Record in App")
                }
            }
            .buttonStyle(GeistButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .secondary))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    private var recordingView: some View {
        VStack(spacing: 24) {
            GeistSectionLabel(number: "01", title: "Status")
            VStack(spacing: 10) {
                Text("Recording")
                    .font(Geist.heading(.largeTitle))
                    .foregroundColor(Geist.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(formatDuration(persistentRecorder.segmentDuration))
                    .font(Geist.mono(size: 48, medium: true))
                    .foregroundColor(Geist.text)
                    .monospacedDigit()
            }
            Text("Return to your app — recording continues")
                .font(Geist.body())
                .foregroundColor(Geist.muted)
                .multilineTextAlignment(.center)
            Button(action: { persistentRecorder.stopInAppSegment() }) {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill").font(.system(.footnote))
                    Text("Stop and Transcribe")
                }
            }
            .buttonStyle(GeistButtonStyle(variant: .destructive))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    private var transcribingView: some View {
        VStack(spacing: 24) {
            GeistSectionLabel(number: "01", title: "Status")
            TranscribingDotsView()
            Text(transcribingStatusText)
                .font(Geist.body())
                .foregroundColor(Geist.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var transcribingStatusText: String {
        guard isProcessingWatchRecordingQueue else {
            return "Processing audio on-device"
        }
        if watchRecordingProcessingTotal > 1 {
            return "Processing Watch recording \(watchRecordingProcessingIndex) of \(watchRecordingProcessingTotal)"
        }
        return "Processing Watch recording"
    }

    private func resultView(_ result: String) -> some View {
        VStack(spacing: 24) {
            GeistSectionLabel(number: "01", title: "Status")
            Text("Transcript Ready")
                .font(Geist.heading(.title))
                .foregroundColor(Geist.text)
                .lineLimit(1)
                .minimumScaleFactor(0.3)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Transcript")
                        .font(Geist.heading(.footnote))
                        .foregroundColor(Geist.muted)
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = result
                        persistentRecorder.lastTranscriptionResult = nil
                    }) {
                        Text("Copy and Clear")
                            .font(Geist.label())
                            .foregroundColor(Geist.text)
                    }
                    .buttonStyle(.plain)
                }
                Text(result)
                    .font(Geist.body())
                    .foregroundColor(Geist.text)
                    .lineSpacing(4)
            }
            .padding(16)
            .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))

            Button(action: { startRecording() }) {
                HStack(spacing: 8) {
                    Image(systemName: usageTracker.isAtLimit ? "lock.fill" : "mic.fill")
                        .font(.system(.footnote))
                    Text(usageTracker.isAtLimit ? "Unlock to Record" : "Record Again")
                }
            }
            .buttonStyle(GeistButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .secondary))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    // MARK: Watch Inbox

    private var watchRecordingInboxView: some View {
        VStack(spacing: 20) {
            GeistSectionLabel(number: "01", title: "Watch Queue")
            VStack(spacing: 8) {
                Text("Watch Recordings")
                    .font(Geist.heading(.title))
                    .foregroundColor(Geist.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(watchInboxSubtitle)
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
                    .multilineTextAlignment(.center)
            }

            if let item = watchRecordingInboxItems.first {
                VStack(spacing: 8) {
                    Text(item.createdAt, style: .relative)
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                    if let duration = item.duration {
                        Text(formatDuration(duration))
                            .font(Geist.mono(size: 36, medium: true))
                            .foregroundColor(Geist.text)
                            .monospacedDigit()
                    }
                }
                .padding(14)
                .frame(maxWidth: 260)
                .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))

                HStack(spacing: 12) {
                    Button(action: { processWatchRecordingQueue() }) {
                        HStack(spacing: 8) {
                            Image(systemName: usageTracker.isAtLimit ? "lock.fill" : "waveform")
                                .font(.system(.footnote))
                            Text(usageTracker.isAtLimit ? "UNLOCK" : watchRecordingProcessButtonTitle)
                        }
                    }
                    .buttonStyle(GeistButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .primary))

                    Button(action: { discardWatchRecording(item) }) {
                        Image(systemName: "trash")
                            .font(.system(.callout, weight: .semibold))
                            .foregroundColor(Geist.text)
                            .frame(width: 52, height: 52)
                            .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Discard Watch recording")
                }
                .frame(maxWidth: 300)
            }
        }
        .padding(.horizontal, 24)
    }

    private var watchInboxSubtitle: String {
        let count = watchRecordingInboxItems.count
        if count == 1 {
            return "1 Watch recording is waiting to be transcribed on this iPhone."
        }
        return "\(count) Watch recordings are waiting to be transcribed on this iPhone."
    }

    private var watchRecordingProcessButtonTitle: String {
        watchRecordingInboxItems.count > 1 ? "Process All" : "Process Recording"
    }

    // MARK: - Bottom Area

    private var bottomArea: some View {
        VStack(spacing: 0) {
            Button(action: { showHistory = true }) {
                Label("View History", systemImage: "clock.arrow.circlepath")
                .font(Geist.label())
                .foregroundColor(Geist.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            GeistDivider()

            if !persistentRecorder.isSegmentActive && !persistentRecorder.isTranscribing {
                HStack(spacing: 12) {
                    Group {
                        if persistentRecorder.isListening {
                            Button(action: { stopPersistentListening() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "stop.fill").font(.system(.footnote))
                                    Text("Stop Listening")
                                }
                            }
                            .buttonStyle(GeistButtonStyle(variant: .secondary))
                        } else {
                            Button(action: { startRecording() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: usageTracker.isAtLimit ? "lock.fill" : "mic.fill").font(.system(.footnote))
                                    Text(usageTracker.isAtLimit ? "Unlock to Record" : "Start Recording")
                                }
                            }
                            .buttonStyle(GeistButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .primary))
                        }
                    }

                    Button(action: { showAudioImporter = true }) {
                        Image(systemName: "waveform")
                            .font(.system(.callout, weight: .semibold))
                            .foregroundColor(Geist.text)
                            .frame(width: 52, height: 52)
                            .background(Geist.Palette.background100)
                            .overlay(
                                RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous)
                                    .stroke(Geist.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
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

    private func reloadWatchRecordingInbox() {
        watchRecordingInboxItems = WatchRecordingInbox.shared.load()
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

    private func autoProcessWatchRecordingQueueIfPossible() {
        guard !isProcessingWatchRecordingQueue else { return }
        guard !watchRecordingInboxItems.isEmpty else { return }
        guard !usageTracker.isAtLimit else { return }
        guard !persistentRecorder.isSegmentActive, !persistentRecorder.isTranscribing else { return }
        processWatchRecordingQueue()
    }

    private func processWatchRecordingQueue() {
        if usageTracker.isAtLimit {
            presentPaywall(context: .recording)
            return
        }
        guard !isProcessingWatchRecordingQueue else { return }
        guard !persistentRecorder.isSegmentActive, !persistentRecorder.isTranscribing else {
            persistentRecorder.lastError = "Wait for the current recording to finish"
            return
        }

        let items = WatchRecordingInbox.shared.load()
        guard !items.isEmpty else {
            reloadWatchRecordingInbox()
            return
        }

        watchRecordingProcessingQueue = items
        watchRecordingProcessingTotal = items.count
        watchRecordingProcessingIndex = 0
        isProcessingWatchRecordingQueue = true
        persistentRecorder.lastTranscriptionResult = nil
        processNextQueuedWatchRecordingIfNeeded()
    }

    private func processNextQueuedWatchRecordingIfNeeded() {
        guard isProcessingWatchRecordingQueue else { return }
        guard !persistentRecorder.isSegmentActive, !persistentRecorder.isTranscribing else { return }

        guard !watchRecordingProcessingQueue.isEmpty else {
            resetWatchRecordingProcessingQueue()
            reloadWatchRecordingInbox()
            return
        }

        if usageTracker.isAtLimit {
            resetWatchRecordingProcessingQueue()
            presentPaywall(context: .recording)
            return
        }

        let item = watchRecordingProcessingQueue.removeFirst()
        watchRecordingProcessingIndex = max(1, watchRecordingProcessingTotal - watchRecordingProcessingQueue.count)

        if persistentRecorder.importAudioFile(from: item.fileURL) {
            WatchRecordingInbox.shared.remove(item)
            reloadWatchRecordingInbox()
        } else {
            resetWatchRecordingProcessingQueue()
            reloadWatchRecordingInbox()
        }
    }

    private func resetWatchRecordingProcessingQueue() {
        isProcessingWatchRecordingQueue = false
        watchRecordingProcessingQueue.removeAll()
        watchRecordingProcessingTotal = 0
        watchRecordingProcessingIndex = 0
    }

    private func discardWatchRecording(_ item: WatchRecordingInboxItem) {
        WatchRecordingInbox.shared.remove(item)
        reloadWatchRecordingInbox()
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

    private func consumePendingWidgetRecordIfNeeded() {
        guard pendingWidgetRecord else { return }
        pendingWidgetRecord = false
        handleWidgetRecord()
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
                    .foregroundColor(Geist.text)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Export Ready")
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                    Text(fileName)
                        .font(Geist.body())
                        .foregroundColor(Geist.text)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("Open File")
                    .font(Geist.label())
                    .foregroundColor(Geist.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Geist.surface2)
            .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
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
            Geist.bg.opacity(0.95).ignoresSafeArea()
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
                    .fill(Geist.surface)
                    .frame(width: 80, height: 80)
                    .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Geist.text)
            }
        case .ready:
            Rectangle()
                .fill(Geist.surface)
                .frame(width: 80, height: 80)
                .overlay(
                    Text("✓")
                        .font(Geist.heading(.largeTitle))
                        .foregroundColor(Geist.text)
                )
                .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
        case .error:
            Rectangle()
                .fill(Geist.surface)
                .frame(width: 80, height: 80)
                .overlay(
                    Text("!")
                        .font(Geist.heading(.largeTitle))
                        .foregroundColor(Geist.error)
                )
                .overlay(Rectangle().stroke(Geist.error, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var phaseText: some View {
        switch phase {
        case .starting:
            VStack(spacing: 10) {
                Text("Starting Microphone…")
                    .font(Geist.heading(.title2))
                    .foregroundColor(Geist.text)
                Text("Setting up always-on listening...")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
            }
        case .ready:
            VStack(spacing: 10) {
                Text("Microphone Ready")
                    .font(Geist.heading(.title))
                    .foregroundColor(Geist.text)
                Text("Return to your app\nand tap Record on the keyboard.")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        case .error:
            VStack(spacing: 10) {
                Text("Microphone Error")
                    .font(Geist.heading(.title))
                    .foregroundColor(Geist.error)
                Text("Check microphone permissions\nin Settings.")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
    }
}
