import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit
import VoxboardShared

private enum KeyboardLaunchPhase: Equatable {
    case starting
    case ready
    case error
}

private struct KeyboardReturnGuidance: Equatable, Identifiable {
    let id = UUID()
    var phase: KeyboardLaunchPhase
}

private enum CaptureRecordingMode: String, CaseIterable, Identifiable {
    case draft
    case preset

    var id: Self { self }
}

struct QuickCaptureView: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @Bindable var persistentRecorder: PersistentRecorder
    @Binding var pendingKeyboardLaunch: Bool
    @Binding var pendingWidgetRecord: Bool
    let captureToolbarPreferences: CaptureToolbarPreferences
    let openSettings: () -> Void

    @Environment(TranscriptStore.self) private var transcriptStore
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(StoreManager.self) private var storeManager
    @Environment(WatchRecordingPipeline.self) private var watchRecordingPipeline
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedScreenshots: [PhotosPickerItem] = []
    @State private var selectedOCRPhotos: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsScreenshotPicker = false
    @State private var showsOCRPhotoPicker = false
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    @State private var showsScanner = false
    @State private var showsJournalPageCapture = false
    @State private var showsSketch = false
    @State private var showsLinkPrompt = false
    @State private var showsCaptureHistory = false
    @State private var showsRoutePicker = false
    @State private var showsDueDate = false
    @State private var showsInternalLinks = false
    @State private var showsPaywall = false
    @State private var paywallContext: OnboardingAnalyticsPaywallContext = .limit
    @State private var showsAudioImporter = false
    @State private var showsVoiceCaptureDetails = false
    @State private var showsWatchRecordingQueue = false
    @State private var recordingMode: CaptureRecordingMode = .preset
    @State private var attachRecordingAudio = false
    @State private var lastStartedRecordingMode: CaptureRecordingMode = .preset
    @State private var micPermissionGranted = Self.currentMicrophonePermissionGranted()
    @State private var keyboardLaunchPhase: KeyboardLaunchPhase?
    @State private var keyboardReturnGuidance: KeyboardReturnGuidance?
    @State private var fileExportToast: FileExportToast?
    @State private var flows: [CapturePreset] = CapturePresetStore.loadFlows()
    @State private var selectedFlowId: String = CapturePresetStore.selectedFlowId()
    @State private var linkText = ""
    @State private var isProcessingMedia = false
    @State private var isExtractingText = false
    @State private var isFindingLocation = false
    @State private var locationRequestTask: Task<Void, Never>?
    @State private var showsSentToast = false
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var composerIsFocused = false
    @State private var hasPerformedInitialLoad = false
    @State private var composerController = MarkdownComposerController()
    @State private var locationService = CaptureLocationService()
    @State private var inspirationQuote = InspirationQuote.fallback
    @State private var hasLoadedInspirationQuote = false

    init(
        viewModel: QuickCaptureViewModel,
        persistentRecorder: PersistentRecorder,
        pendingKeyboardLaunch: Binding<Bool>,
        pendingWidgetRecord: Binding<Bool>,
        captureToolbarPreferences: CaptureToolbarPreferences,
        openSettings: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.persistentRecorder = persistentRecorder
        _pendingKeyboardLaunch = pendingKeyboardLaunch
        _pendingWidgetRecord = pendingWidgetRecord
        self.captureToolbarPreferences = captureToolbarPreferences
        self.openSettings = openSettings
    }

    var body: some View {
        presentedContent
    }

    private var captureContent: some View {
        ZStack(alignment: .top) {
            Geist.Palette.background100.ignoresSafeArea()

            VStack(spacing: 0) {
                if isExtractingText {
                    HStack(spacing: Geist.Spacing.two) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Extracting text on this device…")
                            .font(Geist.caption())
                            .foregroundStyle(Geist.muted)
                        Spacer()
                    }
                    .padding(.horizontal, Geist.Spacing.three)
                    .frame(minHeight: Geist.ControlHeight.medium)
                    .background(Geist.Palette.background200)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("capture_ocr_progress")
                    GeistDivider()
                }

                if viewModel.selectedDestination == nil {
                    emptyDestinationBanner
                    GeistDivider()
                }

                if watchRecordingPipeline.hasVisibleItems {
                    watchRecordingStatusCard
                    GeistDivider()
                }

                composer
                    .layoutPriority(1)

                if !viewModel.draft.additionalPayloads.isEmpty {
                    attachmentStrip
                }
            }

            if let guidance = keyboardReturnGuidance {
                keyboardReturnGuidanceBanner(guidance.phase)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(5)
                    .task(id: guidance.id) {
                        await dismissKeyboardReturnGuidance(after: .seconds(6), id: guidance.id)
                    }
            }

            if let message = captureErrorMessage {
                errorBanner(message)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }

            if let toast = fileExportToast {
                FileExportToastView(fileName: toast.url.lastPathComponent) {
                    openExportedFileInFiles(toast.url)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(4)
            }

            if showsSentToast {
                Label("Capture Sent", systemImage: "checkmark.circle.fill")
                    .font(Geist.label())
                    .foregroundStyle(Geist.Palette.background100)
                    .padding(.horizontal, Geist.Spacing.four)
                    .frame(height: Geist.ControlHeight.medium)
                    .background(Geist.Palette.gray1000)
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(4)
                    .accessibilityIdentifier("capture_sent_toast")
            }
        }
        // Keep the controls owned by the keyboard-aware safe area instead of the
        // flexible editor stack, where a retained first responder can cover them.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            captureControls
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isKeyboardListeningActive {
                    Button(action: togglePersistentListening) {
                        Image(systemName: "headphones")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Geist.Palette.blue700)
                    }
                    .accessibilityLabel("Stop keyboard listening")
                    .accessibilityHint("Turns off voice input for the Vox.md keyboard")
                    .accessibilityIdentifier("capture_keyboard_listening_status")
                }
            }
        }
        .toolbarBackground(Geist.Palette.background100, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var draftLifecycleContent: some View {
        captureContent
            .task {
                await loadAndPresentRequestedInput()
                handleCaptureNeedsUnlock(viewModel.needsCaptureUnlock)
            }
            .onChange(of: viewModel.draft.text) { _, _ in
                if !viewModel.hasLiveRecordedTranscriptPreview {
                    viewModel.scheduleDraftSave()
                }
            }
            .onChange(of: viewModel.draft.voxID) { _, id in
                viewModel.scheduleDraftSave()
                if let id { selectedFlowId = id }
            }
            .onChange(of: viewModel.draft.destinationID) { _, _ in viewModel.scheduleDraftSave() }
            .onChange(of: viewModel.draft.destinationSelectionMode) { _, _ in viewModel.scheduleDraftSave() }
            .onChange(of: viewModel.draft.entryTemplateID) { _, _ in viewModel.scheduleDraftSave() }
            .onChange(of: viewModel.draft.placementOverride) { _, _ in viewModel.scheduleDraftSave() }
            .onChange(of: viewModel.draft.relativeNotePathOverride) { _, _ in viewModel.scheduleDraftSave() }
            .onChange(of: viewModel.errorMessage) { _, message in
                guard let message else { return }
                UIAccessibility.post(notification: .announcement, argument: message)
            }
            .onChange(of: viewModel.needsCaptureUnlock) { _, needsUnlock in
                handleCaptureNeedsUnlock(needsUnlock)
            }
            .onChange(of: viewModel.lastReceipt) { _, receipt in
                guard receipt != nil else { return }
                usageTracker.reload()
                ReviewPromptManager.shared.recordSuccessfulCapture(
                    totalCaptureCount: usageTracker.successfulCapturesUsed
                )
                Task { await presentSentToast() }
            }
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items, prefix: "photo") }
            }
            .onChange(of: selectedScreenshots) { _, items in
                guard !items.isEmpty else { return }
                Task { await importScreenshots(items) }
            }
            .onChange(of: selectedOCRPhotos) { _, items in
                guard !items.isEmpty else { return }
                Task { await importOCRPhotos(items) }
            }
            .onChange(of: viewModel.requestedInput) { _, input in
                handleRequestedInputChange(input)
            }
    }

    private var recordingLifecycleContent: some View {
        draftLifecycleContent
            .onAppear(perform: prepareRecordingFeatures)
            .task { await requestMicrophonePermissionIfNeeded() }
            .onChange(of: pendingKeyboardLaunch) { _, isPending in
                if isPending { consumePendingKeyboardLaunchIfNeeded() }
            }
            .onChange(of: pendingWidgetRecord) { _, isPending in
                if isPending { consumePendingWidgetRecordIfNeeded() }
            }
            .onChange(of: persistentRecorder.needsUnlock) { _, needs in
                handleRecorderNeedsUnlock(needs)
            }
            .onChange(of: persistentRecorder.lastFileExportEvent) { _, event in
                handleFileExportEvent(event)
            }
            .onChange(of: persistentRecorder.lastError) { _, message in
                guard let message else { return }
                UIAccessibility.post(notification: .announcement, argument: message)
            }
            .onChange(of: persistentRecorder.isTranscribing) { _, isTranscribing in
                handleTranscribingChange(isTranscribing)
            }
            .onChange(of: persistentRecorder.isSegmentActive) { _, isActive in
                if !isActive { watchRecordingPipeline.resume() }
            }
            .onChange(of: watchRecordingPipeline.lastDeliveredRecordingID) { _, recordingID in
                guard recordingID != nil else { return }
                usageTracker.reload()
                Task { await viewModel.refreshHistory() }
                Task { await presentSentToast() }
            }
    }

    private var lifecycleContent: some View {
        recordingLifecycleContent
            .task(id: fileExportToast?.id) { await dismissExportToastAfterDelay() }
            .onChange(of: scenePhase) { _, phase in handleScenePhaseChange(phase) }
            .onDisappear(perform: handleCaptureDisappear)
    }

    private var mediaPickerContent: some View {
        lifecycleContent
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: 10,
            matching: .images
        )
        .photosPicker(
            isPresented: $showsScreenshotPicker,
            selection: $selectedScreenshots,
            maxSelectionCount: 10,
            matching: .screenshots
        )
        .photosPicker(
            isPresented: $showsOCRPhotoPicker,
            selection: $selectedOCRPhotos,
            maxSelectionCount: 10,
            selectionBehavior: .ordered,
            matching: .images
        )
        .sheet(isPresented: $showsFileImporter) {
            CaptureFilePicker(
                contentTypes: [.data],
                allowsMultipleSelection: true,
                onPick: { urls in
                    showsFileImporter = false
                    importFiles(urls)
                },
                onCancel: {
                    showsFileImporter = false
                    focusComposer()
                }
            )
            .ignoresSafeArea()
        }
    }

    private var presentedContent: some View {
        mediaPickerContent
        .sheet(isPresented: $showsCaptureHistory) {
            HistoryView(viewModel: viewModel)
                .environment(transcriptStore)
        }
        .sheet(isPresented: $showsWatchRecordingQueue) {
            WatchRecordingQueueView(pipeline: watchRecordingPipeline)
        }
        .sheet(isPresented: $showsRoutePicker, onDismiss: reloadFlows) {
            CaptureRoutePickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showsDueDate) {
            CaptureDueDateSheet { date, includesTime in
                let token = insertionFormatter.dueDateToken(for: date, includeTime: includesTime)
                applyComposerCommand(.replaceSelection(with: token))
                focusComposer()
            }
        }
        .sheet(isPresented: $showsInternalLinks) {
            CaptureInternalLinkPicker(rootURL: viewModel.selectedRootURL()) { markdown in
                applyComposerCommand(.replaceSelection(with: markdown))
                focusComposer()
            }
        }
        .sheet(isPresented: $showsPaywall) {
            PaywallView(context: paywallContext)
                .environment(usageTracker)
                .environment(storeManager)
        }
        .fileImporter(
            isPresented: $showsAudioImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false,
            onCompletion: handleAudioImport
        )
        .sheet(isPresented: $showsCamera) {
            CaptureCameraPicker(
                onCapture: { data in
                    showsCamera = false
                    Task {
                        isProcessingMedia = true
                        await viewModel.stageImage(
                            data: data,
                            filename: "camera-\(captureTimestamp()).jpg",
                            contentTypeIdentifier: UTType.jpeg.identifier
                        )
                        isProcessingMedia = false
                        focusComposer()
                    }
                },
                onCancel: {
                    showsCamera = false
                    focusComposer()
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showsScanner) {
            CaptureDocumentScanner(
                onScan: { pages in
                    showsScanner = false
                    Task {
                        await processScan(pages)
                        focusComposer()
                    }
                },
                onCancel: {
                    showsScanner = false
                    focusComposer()
                },
                onError: { error in
                    showsScanner = false
                    viewModel.errorMessage = error.localizedDescription
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showsJournalPageCapture) {
            CaptureManualJournalPages(
                maxPageCount: 10,
                onCapture: { pages in
                    showsJournalPageCapture = false
                    Task { await processOCRScan(pages) }
                },
                onCancel: {
                    showsJournalPageCapture = false
                    focusComposer()
                }
            )
        }
        .sheet(isPresented: $showsSketch) {
            CaptureSketchEditor(
                onSave: { drawing, preview in
                    showsSketch = false
                    Task {
                        isProcessingMedia = true
                        await viewModel.stageSketch(drawingData: drawing, previewData: preview)
                        isProcessingMedia = false
                        focusComposer()
                    }
                },
                onCancel: {
                    showsSketch = false
                    focusComposer()
                }
            )
        }
        .alert("Capture Link", isPresented: $showsLinkPrompt) {
            TextField("https://example.com", text: $linkText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) { linkText = "" }
            Button("Add") {
                let value = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
                linkText = ""
                if let url = URL(string: value) {
                    Task { await viewModel.addURL(url) }
                } else {
                    viewModel.errorMessage = String(localized: "Enter a valid link.")
                }
            }
        } message: {
            Text("The link stays in your durable draft until the note is captured.")
        }
    }

    private var voiceCaptureButton: some View {
        Group {
            if persistentRecorder.isTranscribing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: persistentRecorder.isSegmentActive ? "stop.fill" : "mic")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(persistentRecorder.isSegmentActive ? Geist.error : Geist.text)
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
        .gesture(voiceCaptureGesture)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(recordingStatusTitle)
        .accessibilityHint("Tap to start or stop. Long-press for detailed recording controls.")
        .accessibilityAction { handleVoiceCaptureTap() }
        .accessibilityAction(named: "Show detailed recording controls") {
            presentVoiceCaptureDetails()
        }
        .accessibilityIdentifier("capture_voice_recording")
        .opacity(isProcessingMedia ? 0.35 : 1)
    }

    private var voiceCaptureGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first:
                    presentVoiceCaptureDetails()
                case .second:
                    handleVoiceCaptureTap()
                }
            }
    }

    private func presentVoiceCaptureDetails() {
        guard !isProcessingMedia else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showsVoiceCaptureDetails = true
        }
    }

    private var voiceCaptureDetailsBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Geist.Spacing.three) {
                Image(systemName: recordingDetailsIcon)
                    .foregroundStyle(recordingDetailsColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recordingDetailsTitle)
                        .font(Geist.label())
                        .foregroundStyle(Geist.text)
                    Text(recordingDetailsSubtitle)
                        .font(Geist.caption(.caption2))
                        .foregroundStyle(Geist.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: Geist.Spacing.two)
                recordingPrimaryButton

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsVoiceCaptureDetails = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide detailed recording controls")
            }
            .padding(.horizontal, Geist.Spacing.three)
            .padding(.vertical, Geist.Spacing.two)

            GeistDivider()

            VStack(alignment: .leading, spacing: Geist.Spacing.three) {
                Picker("Recording result", selection: $recordingMode) {
                    Text("Add to Draft").tag(CaptureRecordingMode.draft)
                    Text("Send Immediately").tag(CaptureRecordingMode.preset)
                }
                .pickerStyle(.segmented)
                .disabled(recordingOptionsAreLocked)
                .accessibilityIdentifier("capture_recording_mode")

                HStack(spacing: Geist.Spacing.three) {
                    Menu {
                        ForEach(enabledFlows) { flow in
                            Button(flow.displayName) { selectFlow(flow) }
                        }
                    } label: {
                        Label(selectedFlow.displayName, systemImage: selectedFlow.symbolName)
                            .font(Geist.label())
                            .lineLimit(1)
                            .padding(.horizontal, Geist.Spacing.three)
                            .frame(height: Geist.ControlHeight.medium)
                            .background(Geist.Palette.background100)
                            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
                    }
                    .disabled(recordingOptionsAreLocked)
                    .accessibilityLabel("Capture Preset \(selectedFlow.displayName)")

                    if recordingMode == .draft {
                        Toggle(isOn: $attachRecordingAudio) {
                            Label("Audio", systemImage: "paperclip")
                                .font(Geist.caption())
                        }
                        .toggleStyle(.switch)
                        .tint(Geist.Palette.blue700)
                        .disabled(recordingOptionsAreLocked)
                        .accessibilityLabel("Attach audio to Capture")
                    }

                    Spacer(minLength: 0)

                    Button {
                        showsAudioImporter = true
                    } label: {
                        Image(systemName: "waveform.badge.plus")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(recordingOptionsAreLocked)
                    .accessibilityLabel("Import audio")
                    .accessibilityIdentifier("capture_audio_import")

                    Button(action: togglePersistentListening) {
                        Image(systemName: persistentRecorder.isListening ? "headphones.circle.fill" : "headphones.circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(persistentRecorder.isListening ? Geist.Palette.blue700 : Geist.text)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(recordingOptionsAreLocked)
                    .accessibilityLabel(persistentRecorder.isListening ? "Stop keyboard listening" : "Start keyboard listening")
                    .accessibilityIdentifier("capture_keyboard_listening")
                }

                if !usageTracker.hasUnlocked {
                    recordingUsageMeter
                }

                if let phase = keyboardLaunchPhase {
                    keyboardListeningStatusRow(phase)
                }

                if let result = persistentRecorder.lastTranscriptionResult {
                    HStack(spacing: Geist.Spacing.two) {
                        Image(systemName: lastStartedRecordingMode == .draft ? "text.badge.plus" : "checkmark.circle.fill")
                        Text(lastStartedRecordingMode == .draft ? "Transcript added to Capture" : "Sent with Preset")
                            .font(Geist.caption())
                        Spacer()
                        Button("Copy") { UIPasteboard.general.string = result }
                            .font(Geist.caption())
                    }
                    .foregroundStyle(Geist.muted)
                }
            }
            .padding(Geist.Spacing.three)
        }
        .background(Geist.Palette.background200)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("capture_recording_details")
    }

    @ViewBuilder
    private var recordingPrimaryButton: some View {
        if persistentRecorder.isSegmentActive {
            Button(action: { persistentRecorder.stopInAppSegment() }) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(GeistButtonStyle(variant: .destructive, size: .small))
            .accessibilityIdentifier("capture_recording_stop")
        } else if persistentRecorder.isTranscribing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 72, height: 36)
                .accessibilityLabel("Transcribing recording")
        } else {
            Button(action: startInlineRecording) {
                Label(
                    usageTracker.isAtLimit ? "Unlock" : "Record",
                    systemImage: usageTracker.isAtLimit ? "lock.fill" : "mic.fill"
                )
            }
            .buttonStyle(GeistButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .primary, size: .small))
            .accessibilityIdentifier("capture_recording_start")
        }
    }

    private var recordingUsageMeter: some View {
        Button(action: { presentPaywall(context: .usageMeter) }) {
            HStack(spacing: Geist.Spacing.two) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Geist.Palette.gray200).frame(height: 2)
                        Rectangle()
                            .fill(usageTracker.isAtLimit ? Geist.error : Geist.text)
                            .frame(width: geometry.size.width * usageTracker.fractionUsed, height: 2)
                    }
                }
                .frame(height: 2)
                Text(recordingUsageLabel)
                    .font(Geist.mono())
                    .foregroundStyle(usageTracker.isAtLimit ? Geist.error : Geist.muted)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
    }

    private func keyboardListeningStatusRow(_ phase: KeyboardLaunchPhase) -> some View {
        HStack(spacing: Geist.Spacing.two) {
            switch phase {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Preparing keyboard listening…")
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Geist.Palette.blue700)
                Text("Keyboard listening is ready")
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Geist.error)
                Text("Keyboard listening could not start")
            }
            Spacer()
        }
        .font(Geist.caption())
    }

    private func keyboardReturnGuidanceBanner(_ phase: KeyboardLaunchPhase) -> some View {
        HStack(alignment: .top, spacing: Geist.Spacing.three) {
            Group {
                switch phase {
                case .starting:
                    ProgressView()
                        .controlSize(.small)
                case .ready:
                    Image(systemName: "keyboard.fill")
                        .foregroundStyle(Geist.Palette.blue700)
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Geist.error)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                Text(keyboardReturnGuidanceTitle(for: phase))
                    .font(Geist.label())
                    .foregroundStyle(Geist.text)
                Text(keyboardReturnGuidanceMessage(for: phase))
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Geist.Spacing.two)

            Button {
                withAnimation(.easeIn(duration: 0.18)) {
                    keyboardReturnGuidance = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss keyboard listening message")
        }
        .padding(Geist.Spacing.three)
        .background(phase == .error ? Geist.Palette.red100 : Geist.Palette.blue100)
        .overlay {
            RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous)
                .stroke(
                    phase == .error ? Geist.Palette.red400 : Geist.Palette.blue400,
                    lineWidth: 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous))
        .accessibilityIdentifier("keyboard_return_guidance")
    }

    private func keyboardReturnGuidanceTitle(for phase: KeyboardLaunchPhase) -> String {
        switch phase {
        case .starting:
            return String(localized: "Turning on keyboard listening")
        case .ready:
            return String(localized: "Keyboard listening is on")
        case .error:
            return String(localized: "Keyboard listening couldn't start")
        }
    }

    private func keyboardReturnGuidanceMessage(for phase: KeyboardLaunchPhase) -> String {
        switch phase {
        case .starting:
            return String(localized: "Vox.md opened to enable voice input. When it’s ready, return to your keyboard to use it.")
        case .ready:
            return String(localized: "Return to your keyboard to start using voice input.")
        case .error:
            return String(localized: "Check microphone access, then try again from your keyboard.")
        }
    }

    private func handleVoiceCaptureTap() {
        if persistentRecorder.isSegmentActive {
            // Never block stopping an active recording because unrelated media
            // work happens to be finishing in the draft.
            persistentRecorder.stopInAppSegment()
        } else if !isProcessingMedia,
                  !persistentRecorder.isTranscribing,
                  !watchRecordingPipeline.isProcessing {
            startInlineRecording()
        }
    }

    private var canExtractJournalText: Bool {
        !persistentRecorder.isSegmentActive
            && !persistentRecorder.isTranscribing
            && !watchRecordingPipeline.isProcessing
            && !viewModel.hasLiveRecordedTranscriptPreview
    }

    private func requireIdleVoiceCaptureForOCR() -> Bool {
        guard canExtractJournalText else {
            viewModel.errorMessage = String(
                localized: "Finish the current voice capture before extracting journal text."
            )
            return false
        }
        return true
    }

    private var recordingOptionsAreLocked: Bool {
        persistentRecorder.isSegmentActive
            || persistentRecorder.isTranscribing
            || watchRecordingPipeline.isProcessing
            || isProcessingMedia
    }

    private var recordingUsageLabel: String {
        usageTracker.isAtLimit
            ? String(localized: "Limit reached · Unlock")
            : String(format: String(localized: "%.1f / 15 min free"), usageTracker.minutesUsed)
    }

    private var captureControls: some View {
        VStack(spacing: 0) {
            if showsVoiceCaptureDetails {
                GeistDivider()
                voiceCaptureDetailsBar
                GeistDivider()
            }
            routeSelectionRow
            GeistDivider()
            captureActionBar
            GeistDivider()
            CaptureEditorToolbar(
                command: handleToolbarCommand,
                showDueDate: { showsDueDate = true },
                insertLocation: insertCurrentLocation,
                showSketch: { showsSketch = true },
                showCamera: { showsCamera = true },
                showPhotos: { showsPhotoPicker = true },
                showScreenshots: { showsScreenshotPicker = true },
                showLinkPrompt: { showsLinkPrompt = true },
                showFiles: presentFileImporter,
                showScan: { showsScanner = VNDocumentCameraViewController.isSupported },
                captureTextPages: {
                    showsJournalPageCapture = UIImagePickerController.isSourceTypeAvailable(.camera)
                },
                chooseTextPhotos: { showsOCRPhotoPicker = true },
                canExtractText: canExtractJournalText,
                canCaptureTextPages: UIImagePickerController.isSourceTypeAvailable(.camera),
                isProcessingMedia: isProcessingMedia,
                isFindingLocation: isFindingLocation,
                preferences: captureToolbarPreferences
            )
        }
        .background(Geist.Palette.background100)
    }

    private var composer: some View {
        MarkdownComposerTextView(
            text: $viewModel.draft.text,
            selection: $composerSelection,
            isFocused: $composerIsFocused,
            controller: composerController
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Geist.Palette.background100)
        .overlay(alignment: .topLeading) {
            if viewModel.draft.text.isEmpty && !composerIsFocused {
                BlinkingCaptureCaret()
                    .padding(.leading, 21)
                    .padding(.top, 24)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .center) {
            if viewModel.draft.text.isEmpty && viewModel.draft.additionalPayloads.isEmpty {
                inspirationPlaceholder
                    .task { await loadInspirationQuote() }
            }
        }
    }

    @ViewBuilder
    private var inspirationPlaceholder: some View {
        VStack(spacing: Geist.Spacing.three) {
            if let prompt = activeCapturePrompt {
                Image(systemName: selectedFlow.symbolName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Geist.faint)
                Text(prompt)
                    .font(Geist.body(.title3))
                    .foregroundStyle(Geist.faint)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                Text(selectedFlow.displayName)
                    .font(Geist.caption())
                    .foregroundStyle(Geist.faint)
            } else {
                VStack(spacing: Geist.Spacing.two) {
                    Text(verbatim: "“\(inspirationQuote.text)”")
                        .font(Geist.body(.title3))
                        .foregroundStyle(Geist.faint)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)

                    Text(verbatim: "— \(inspirationQuote.author)")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.faint)
                }
                .accessibilityElement(children: .combine)

                Link(
                    "ZenQuotes ↗",
                    destination: URL(string: "https://zenquotes.io/")!
                )
                .font(Geist.caption(.caption2))
                .foregroundStyle(Geist.faint)
                .accessibilityLabel("Inspirational quotes provided by ZenQuotes API")
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 28)
    }

    private var activeCapturePrompt: String? {
        let trimmed = selectedFlow.capturePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    private var watchRecordingStatusCard: some View {
        if let item = watchRecordingPipeline.currentItem {
            VStack(alignment: .leading, spacing: Geist.Spacing.two) {
                HStack(spacing: Geist.Spacing.three) {
                    Button {
                        dismissComposer()
                        showsWatchRecordingQueue = true
                    } label: {
                        HStack(spacing: Geist.Spacing.three) {
                            Image(systemName: item.watchStatusSymbol)
                                .foregroundStyle(item.phase == .failed ? Geist.error : Geist.text)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.watchStatusTitle)
                                    .font(Geist.label())
                                Text(item.watchStatusSubtitle)
                                    .font(Geist.caption(.caption2))
                                    .foregroundStyle(item.phase == .failed ? Geist.error : Geist.muted)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Geist.Spacing.two)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if item.phase == .transcribing || item.phase == .delivering {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        dismissComposer()
                        showsWatchRecordingQueue = true
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(Geist.caption(.caption2))
                            .foregroundStyle(Geist.faint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show Watch recording queue")
                }

                if item.isWaitingForTranscriptionUpgrade {
                    Button("Get Vox.md Unlimited") { presentPaywall(context: .limit) }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(GeistButtonStyle(variant: .primary, size: .small))
                } else if item.phase == .failed {
                    Button("Retry") { watchRecordingPipeline.retry(item) }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .foregroundStyle(Geist.text)
            .background(Geist.surface)
            .accessibilityIdentifier("watch_recording_status")
        }
    }

    private var emptyDestinationBanner: some View {
        Button {
            dismissComposer()
            showsRoutePicker = true
        } label: {
            HStack(spacing: Geist.Spacing.two) {
                Image(systemName: "folder.badge.plus")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Destination Not Configured")
                        .font(Geist.label())
                    Text("Set up where this Capture Preset writes Markdown")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
                Spacer(minLength: Geist.Spacing.two)
                Text("Set Up")
                    .font(Geist.caption())
                Image(systemName: "chevron.right")
                    .font(Geist.caption(.caption2))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .foregroundStyle(Geist.text)
            .background(Geist.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("capture_destination_banner")
    }

    private var routeSelectionRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(enabledFlows) { flow in
                    Button {
                        selectFlow(flow)
                    } label: {
                        Label(flow.displayName, systemImage: flow.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedFlow.symbolName)
                    Text(selectedFlow.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .accessibilityLabel("Capture Preset \(selectedFlow.displayName)")
            .accessibilityIdentifier("capture_vox_selector")

            Button {
                dismissComposer()
                showsRoutePicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.hasAnyRouteOverride ? "arrow.triangle.branch" : "tray.full")
                    Text(routeLabel)
                        .lineLimit(1)
                    if viewModel.hasAnyRouteOverride {
                        Text("Override")
                            .font(Geist.caption(.caption2))
                            .foregroundStyle(Geist.faint)
                    }
                }
            }
            .accessibilityLabel("Capture route \(routeLabel), \(viewModel.effectivePlacementLabel)")

            if viewModel.hasAnyRouteOverride {
                Button {
                    viewModel.useVoxRouteDefaults()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Use Preset destination defaults")
            }

            Spacer(minLength: 4)
        }
        .font(Geist.caption())
        .foregroundStyle(Geist.muted)
        .padding(.horizontal, Geist.Spacing.three)
        .frame(minHeight: Geist.ControlHeight.medium)
        .background(Geist.Palette.background100)
    }

    private var captureActionBar: some View {
        HStack(spacing: 8) {
            routeStatusButton(
                "Recent captures",
                icon: "clock.arrow.circlepath"
            ) {
                dismissComposer()
                showsCaptureHistory = true
            }

            routeStatusButton(
                "Settings",
                icon: "gearshape"
            ) {
                dismissComposer()
                openSettings()
            }
            .accessibilityIdentifier("capture_settings")

            Spacer(minLength: 4)

            if !usageTracker.hasUnlocked, usageTracker.successfulCapturesUsed >= 7 {
                Button {
                    presentPaywall(context: .usageMeter)
                } label: {
                    Text(usageTracker.isCaptureAtLimit
                         ? String(localized: "Unlock")
                         : String(localized: "\(usageTracker.capturesRemaining) free"))
                        .font(Geist.mono(.caption2, medium: true))
                        .foregroundStyle(usageTracker.isCaptureAtLimit ? Geist.error : Geist.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(usageTracker.capturesRemaining) free captures remaining")
            }

            routeStatusButton(
                viewModel.isSubmitting
                    ? "Sending capture"
                    : (captureSubmissionRequiresUnlock ? "Unlock unlimited captures" : "Send capture"),
                icon: captureSubmissionRequiresUnlock ? "lock.fill" : "arrow.up"
            ) {
                if captureSubmissionRequiresUnlock {
                    presentPaywall(context: .captureLimit)
                } else {
                    Task { await viewModel.submit() }
                }
            }
            .disabled(!viewModel.canSubmit || captureSubmissionIsBlocked)
            .opacity(viewModel.canSubmit && !captureSubmissionIsBlocked ? 1 : 0.35)
            .accessibilityIdentifier("quick_capture_submit")

            voiceCaptureButton

            routeStatusButton(
                composerIsFocused ? "Dismiss keyboard" : "Show keyboard",
                icon: composerIsFocused ? "keyboard.chevron.compact.down" : "keyboard"
            ) {
                toggleKeyboard()
            }
        }
        .font(Geist.caption())
        .foregroundStyle(Geist.muted)
        .padding(.horizontal, Geist.Spacing.three)
        .frame(minHeight: Geist.ControlHeight.large)
        .background(Geist.Palette.background200)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.draft.additionalPayloads.enumerated()), id: \.offset) { index, payload in
                    HStack(spacing: 7) {
                        Image(systemName: payloadIcon(payload))
                        Text(payloadLabel(payload))
                            .lineLimit(1)
                        Button {
                            Task { await viewModel.removePayload(at: index) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .accessibilityLabel("Remove \(payloadLabel(payload))")
                    }
                    .font(Geist.caption())
                    .foregroundStyle(Geist.text)
                    .padding(.horizontal, Geist.Spacing.three)
                    .frame(height: 36)
                    .background(Geist.Palette.gray100)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Geist.Palette.background100)
        .accessibilityLabel("Capture attachments")
    }

    private var captureErrorMessage: String? {
        viewModel.errorMessage ?? persistentRecorder.lastError
    }

    private func dismissCaptureError() {
        if viewModel.errorMessage != nil {
            viewModel.errorMessage = nil
        } else {
            persistentRecorder.lastError = nil
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Geist.error)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(Geist.caption())
                    .foregroundStyle(Geist.text)
                if viewModel.errorMessage != nil, viewModel.failedInboxCount > 0 {
                    Button("Retry queued captures") {
                        Task { await viewModel.retryFailedInbox() }
                    }
                    .font(Geist.caption())
                }
            }
            Spacer()
            Button(action: dismissCaptureError) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding(Geist.Spacing.three)
        .background(Geist.Palette.red100)
        .overlay(
            RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous)
                .stroke(Geist.Palette.red400, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
    }

    private func routeStatusButton(
        _ accessibilityLabel: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Geist.text)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var routeLabel: String {
        if let override = viewModel.draft.relativeNotePathOverride {
            return URL(fileURLWithPath: override).deletingPathExtension().lastPathComponent
        }
        return viewModel.selectedDestination?.rootName ?? String(localized: "Set up destination")
    }

    private var captureSubmissionRequiresUnlock: Bool {
        usageTracker.isCaptureAtLimit
            && viewModel.draft.deliveryKind == .standard
    }

    private var captureSubmissionIsBlocked: Bool {
        isProcessingMedia || persistentRecorder.isSegmentActive || persistentRecorder.isTranscribing
    }

    private var isKeyboardListeningActive: Bool {
        persistentRecorder.isListening
            && AppConstants.sharedDefaults?.bool(forKey: AppConstants.autoListenEnabledKey) == true
    }

    private var insertionFormatter: CaptureInsertionFormatter {
        CaptureInsertionFormatter(calendar: calendar, locale: locale, timeZone: timeZone)
    }

    private func handleToolbarCommand(_ command: CaptureEditorToolbarCommand) {
        switch command {
        case .undo:
            composerController.undo()
        case .bold:
            applyComposerCommand(.toggleBold)
        case .italic:
            applyComposerCommand(.toggleItalic)
        case .hashtag:
            applyComposerCommand(.insertHashtag)
        case .heading(let level):
            applyComposerCommand(.heading(level: level))
        case .markdownLink:
            applyComposerCommand(.markdownLink())
        case .checklist:
            applyComposerCommand(.taskCheckbox)
        case .bulletList:
            applyComposerCommand(.bullet)
        case .paste:
            if let value = UIPasteboard.general.string {
                applyComposerCommand(.replaceSelection(with: value))
            }
        case .internalLink:
            dismissComposer()
            showsInternalLinks = true
        case .timestamp:
            applyComposerCommand(.replaceSelection(with: insertionFormatter.currentTimestamp()))
        case .date:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            applyComposerCommand(.replaceSelection(with: formatter.string(from: Date())))
        case .lowercase:
            applyComposerCommand(.lowercase)
        case .uppercase:
            applyComposerCommand(.uppercase)
        case .sentenceCase:
            applyComposerCommand(.sentenceCase)
        case .capitalizeWords:
            applyComposerCommand(.capitalizeWords)
        case .slugify:
            applyComposerCommand(.slugify)
        }
    }

    private func applyComposerCommand(_ command: CaptureComposerCommand) {
        let result = CaptureComposerTextEditor().applying(
            command,
            to: composerController.text,
            selection: composerController.selection
        )
        composerController.replaceAll(with: result.text, selection: result.selection.nsRange)
        focusComposer()
    }

    private func handleRequestedInputChange(_ input: CaptureRequestedInput?) {
        guard let input else { return }
        presentRequestedInput(input)
        viewModel.requestedInput = nil
    }

    private func presentFileImporter() {
        dismissComposer()
        showsFileImporter = true
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        // Permission prompts make the scene temporarily inactive. Keep explicit
        // one-shot requests alive until the app actually backgrounds.
        guard phase == .background else { return }
        locationRequestTask?.cancel()
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Save Capture draft"
        )
        Task {
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            await viewModel.saveDraftNow()
        }
    }

    private func handleCaptureDisappear() {
        locationRequestTask?.cancel()
        dismissComposer()
    }

    private func insertCurrentLocation() {
        guard locationRequestTask == nil else { return }
        isFindingLocation = true
        locationRequestTask = Task { @MainActor in
            defer {
                isFindingLocation = false
                locationRequestTask = nil
            }
            do {
                let location = try await locationService.requestCurrentLocation()
                try Task.checkCancellation()
                let markdown = try insertionFormatter.googleMapsLink(
                    latitude: location.latitude,
                    longitude: location.longitude,
                    label: location.label
                )
                applyComposerCommand(.replaceSelection(with: markdown))
            } catch is CancellationError {
                // Leaving Capture cancels the explicit one-shot request.
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func toggleKeyboard() {
        if composerIsFocused {
            dismissComposer()
        } else {
            focusComposer()
        }
    }

    private func dismissComposer() {
        composerIsFocused = false
        composerController.dismissKeyboard()
    }

    private func loadInspirationQuote() async {
        guard activeCapturePrompt == nil, !hasLoadedInspirationQuote else { return }
        let quote = await InspirationQuoteService.shared.nextQuote()
        guard !Task.isCancelled else { return }
        inspirationQuote = quote
        hasLoadedInspirationQuote = true
    }

    private func focusComposer() {
        composerIsFocused = true
    }

    private func loadAndPresentRequestedInput() async {
        // Navigation restarts this task when Capture reappears. Auto-focusing on
        // every restart races the pop transition and can put the keyboard over
        // controls before SwiftUI has restored the keyboard safe area.
        let shouldAutoFocus = !hasPerformedInitialLoad
        hasPerformedInitialLoad = true

        await viewModel.load()
        guard !Task.isCancelled else { return }
        reloadFlows()
        if let input = viewModel.requestedInput {
            presentRequestedInput(input)
            viewModel.requestedInput = nil
        } else if shouldAutoFocus {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            focusComposer()
        }
    }

    private func presentRequestedInput(_ input: CaptureRequestedInput) {
        dismissComposer()
        switch input {
        case .photos: showsPhotoPicker = true
        case .screenshots: showsScreenshotPicker = true
        case .camera: showsCamera = true
        case .files: presentFileImporter()
        case .scan: showsScanner = VNDocumentCameraViewController.isSupported
        case .sketch: showsSketch = true
        case .link: showsLinkPrompt = true
        case .voice:
            recordingMode = .draft
            startInlineRecording()
        }
    }

    private func presentSentToast() async {
        withAnimation(.easeOut(duration: 0.18)) { showsSentToast = true }
        UIAccessibility.post(notification: .announcement, argument: "Capture sent")
        try? await Task.sleep(for: .seconds(2))
        withAnimation(.easeIn(duration: 0.18)) { showsSentToast = false }
        focusComposer()
    }

    private func importPhotos(_ items: [PhotosPickerItem], prefix: String) async {
        isProcessingMedia = true
        defer {
            selectedPhotos = []
            isProcessingMedia = false
            focusComposer()
        }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first ?? .jpeg
                let ext = type.preferredFilenameExtension ?? "jpg"
                await viewModel.stageImage(
                    data: data,
                    filename: "\(prefix)-\(UUID().uuidString.lowercased()).\(ext)",
                    contentTypeIdentifier: type.identifier
                )
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func importOCRPhotos(_ items: [PhotosPickerItem]) async {
        guard requireIdleVoiceCaptureForOCR() else {
            selectedOCRPhotos = []
            focusComposer()
            return
        }
        isProcessingMedia = true
        isExtractingText = true
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "Extracting text on this device")
        )
        defer {
            selectedOCRPhotos = []
            isExtractingText = false
            isProcessingMedia = false
            focusComposer()
        }

        do {
            var pages: [Data] = []
            pages.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw JournalImageOCRProcessorError.unreadableImage(page: index + 1)
                }
                pages.append(data)
            }
            try await extractJournalText(from: pages)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func importScreenshots(_ items: [PhotosPickerItem]) async {
        isProcessingMedia = true
        defer {
            selectedScreenshots = []
            isProcessingMedia = false
            focusComposer()
        }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first ?? .png
                let ext = type.preferredFilenameExtension ?? "png"
                await viewModel.stageImage(
                    data: data,
                    filename: "screenshot-\(UUID().uuidString.lowercased()).\(ext)",
                    contentTypeIdentifier: type.identifier,
                    altText: String(localized: "Screenshot")
                )
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            isProcessingMedia = true
            defer {
                isProcessingMedia = false
                focusComposer()
            }
            do {
                var budget = CaptureInputBudget()
                try budget.reserveSharedItems(urls.count)
                for url in urls {
                    let values = try url.resourceValues(forKeys: [.contentTypeKey])
                    let type = values.contentType ?? .data
                    await viewModel.stageFile(
                        at: url,
                        filename: url.lastPathComponent,
                        contentTypeIdentifier: type.identifier,
                        embedAsImage: type.conforms(to: .image),
                        embedAsAudio: type.conforms(to: .audio)
                    )
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func processScan(_ pages: [Data]) async {
        isProcessingMedia = true
        defer { isProcessingMedia = false }
        do {
            let scan = try await DocumentScanProcessor.process(pageImages: pages)
            await viewModel.stageScan(
                pageImages: scan.pageImages,
                pdfData: scan.pdfData,
                extractedText: scan.extractedText
            )
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func processOCRScan(_ pages: [Data]) async {
        guard requireIdleVoiceCaptureForOCR() else {
            focusComposer()
            return
        }
        isProcessingMedia = true
        isExtractingText = true
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "Extracting text on this device")
        )
        defer {
            isExtractingText = false
            isProcessingMedia = false
            focusComposer()
        }

        do {
            try await extractJournalText(from: pages)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func extractJournalText(from pages: [Data]) async throws {
        let markdown = try await JournalImageOCRProcessor.process(pageImages: pages)
        // Watch delivery can begin while a picker or Vision request is active.
        // Never merge two asynchronous transcript sources into the same draft.
        guard requireIdleVoiceCaptureForOCR() else { return }
        guard await viewModel.appendRecognizedText(markdown) else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "Extracted text added to Capture")
        )
    }

    // MARK: - Inline recording

    private static func currentMicrophonePermissionGranted() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    private var enabledFlows: [CapturePreset] {
        let enabled = flows.filter(\.isEnabled)
        return enabled.isEmpty ? CapturePresetStore.defaultFlows : enabled
    }

    private var selectedFlow: CapturePreset {
        enabledFlows.first(where: { $0.id == selectedFlowId }) ?? enabledFlows[0]
    }

    private var selectedRecordingCompletionMode: RecordingCompletionMode {
        switch recordingMode {
        case .draft:
            return .captureDraft(attachAudio: attachRecordingAudio)
        case .preset:
            return .runVox(flowID: selectedFlow.id)
        }
    }

    private var recordingDetailsTitle: String {
        if persistentRecorder.isSegmentActive {
            return String(localized: "Recording \(formatRecordingDuration(persistentRecorder.segmentDuration))")
        }
        if persistentRecorder.isTranscribing {
            return String(localized: "Transcribing")
        }
        if persistentRecorder.isListening { return String(localized: "Keyboard Listening On") }
        return String(localized: "Voice Capture")
    }

    private var recordingDetailsSubtitle: String {
        if persistentRecorder.isSegmentActive {
            return String(localized: "Composer remains available while you record")
        }
        if persistentRecorder.isTranscribing {
            return lastStartedRecordingMode == .draft
                ? String(localized: "Adding transcript to this Capture")
                : String(localized: "Running \(selectedFlow.displayName)")
        }
        if persistentRecorder.isListening {
            return String(localized: "Ready for the Vox.md keyboard in any app")
        }
        return recordingMode == .draft
            ? String(localized: "Transcript will be added to the editor")
            : String(localized: "Record and export with \(selectedFlow.displayName)")
    }

    private var recordingDetailsIcon: String {
        if persistentRecorder.isSegmentActive { return "record.circle.fill" }
        if persistentRecorder.isTranscribing { return "waveform.badge.magnifyingglass" }
        if persistentRecorder.isListening { return "headphones.circle.fill" }
        return "waveform.circle"
    }

    private var recordingDetailsColor: Color {
        if persistentRecorder.isSegmentActive { return Geist.error }
        if persistentRecorder.isTranscribing || persistentRecorder.isListening {
            return Geist.Palette.blue700
        }
        return Geist.text
    }

    private var recordingStatusTitle: String {
        if persistentRecorder.isSegmentActive {
            return String(localized: "Stop voice recording, \(formatRecordingDuration(persistentRecorder.segmentDuration))")
        }
        if persistentRecorder.isTranscribing {
            return String(localized: "Transcribing voice capture")
        }
        if usageTracker.isAtLimit { return String(localized: "Unlock voice capture") }
        return recordingMode == .draft
            ? String(localized: "Start voice capture and add transcript to Capture")
            : String(localized: "Start voice capture and run \(selectedFlow.displayName)")
    }

    private func prepareRecordingFeatures() {
        reloadFlows()
        consumePendingKeyboardLaunchIfNeeded()
        consumePendingWidgetRecordIfNeeded()
        watchRecordingPipeline.resume()
    }

    private func requestMicrophonePermissionIfNeeded() async {
        let granted = await AudioRecorder.requestMicrophonePermission()
        micPermissionGranted = granted
        OnboardingAnalyticsClient.shared.trackMicrophonePermissionCompleted(
            status: granted ? .granted : .denied,
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )
    }

    private func reloadFlows() {
        flows = CapturePresetStore.loadFlows()
        viewModel.refreshVoxProfiles()
        let draftVoxID = viewModel.draft.voxID
        selectedFlowId = flows.contains(where: { $0.id == draftVoxID && $0.isEnabled })
            ? (draftVoxID ?? CapturePresetStore.generalId)
            : (viewModel.selectedVoxProfile?.id ?? CapturePresetStore.selectedFlowId())
    }

    private func selectFlow(_ flow: CapturePreset) {
        viewModel.selectVox(flow.id)
        selectedFlowId = flow.id
        WatchRecordingController.shared.publishState()
    }

    private func startInlineRecording() {
        if usageTracker.isAtLimit {
            presentPaywall(context: .recording)
            return
        }
        guard micPermissionGranted else {
            persistentRecorder.lastError = String(localized: "Enable microphone access in Settings to record audio.")
            return
        }
        guard !persistentRecorder.isSegmentActive,
              !persistentRecorder.isTranscribing,
              !watchRecordingPipeline.isProcessing,
              !isProcessingMedia else { return }

        lastStartedRecordingMode = recordingMode
        persistentRecorder.lastTranscriptionResult = nil
        _ = persistentRecorder.startOneShotInAppSegment(
            flowId: selectedFlow.id,
            completionMode: selectedRecordingCompletionMode
        )
    }

    private func togglePersistentListening() {
        if persistentRecorder.isListening {
            persistentRecorder.stopListening()
            AppConstants.sharedDefaults?.set(false, forKey: AppConstants.autoListenEnabledKey)
            keyboardLaunchPhase = nil
            withAnimation(.easeIn(duration: 0.18)) {
                keyboardReturnGuidance = nil
            }
        } else {
            handleKeyboardLaunch()
        }
    }

    private func handleAudioImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if usageTracker.isAtLimit {
                presentPaywall(context: .recording)
                return
            }
            lastStartedRecordingMode = recordingMode
            persistentRecorder.lastTranscriptionResult = nil
            _ = persistentRecorder.importAudioFile(
                from: url,
                completionMode: selectedRecordingCompletionMode
            )
        case .failure(let error):
            persistentRecorder.lastError = error.localizedDescription
        }
    }

    private func presentPaywall(context: OnboardingAnalyticsPaywallContext) {
        paywallContext = context
        showsPaywall = true
    }

    private func handleCaptureNeedsUnlock(_ needsUnlock: Bool) {
        guard needsUnlock else { return }
        viewModel.needsCaptureUnlock = false
        usageTracker.reload()
        guard !usageTracker.hasUnlocked else {
            Task { await viewModel.processPendingInbox() }
            return
        }
        presentPaywall(context: .captureLimit)
    }

    private func consumePendingKeyboardLaunchIfNeeded() {
        guard pendingKeyboardLaunch else { return }
        pendingKeyboardLaunch = false

        let guidance = KeyboardReturnGuidance(phase: .starting)
        withAnimation(.easeOut(duration: 0.18)) {
            keyboardReturnGuidance = guidance
        }
        handleKeyboardLaunch(guidanceID: guidance.id)
    }

    private func handleKeyboardLaunch(guidanceID: UUID? = nil) {
        keyboardLaunchPhase = .starting
        updateKeyboardReturnGuidance(.starting, id: guidanceID)
        OnboardingAnalyticsClient.shared.trackKeyboardSetupStarted(
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )
        Task { @MainActor in
            if !persistentRecorder.isListening {
                persistentRecorder.startListening()
            }
            let backendReady = await persistentRecorder.prepareTranscriptionBackend()
            let isReady = persistentRecorder.isListening && backendReady
            let completedPhase: KeyboardLaunchPhase = isReady ? .ready : .error
            keyboardLaunchPhase = completedPhase
            updateKeyboardReturnGuidance(completedPhase, id: guidanceID)
            UIAccessibility.post(
                notification: .announcement,
                argument: isReady
                    ? String(localized: "Keyboard listening is ready. Return to your keyboard to use it.")
                    : String(localized: "Keyboard listening could not start")
            )
            if isReady {
                OnboardingAnalyticsClient.shared.trackKeyboardSetupCompleted(
                    quotaState: usageTracker.onboardingAnalyticsQuotaState
                )
            }
            try? await Task.sleep(for: .seconds(2.5))
            if keyboardLaunchPhase == completedPhase { keyboardLaunchPhase = nil }
        }
    }

    private func updateKeyboardReturnGuidance(_ phase: KeyboardLaunchPhase, id: UUID?) {
        guard let id, var guidance = keyboardReturnGuidance, guidance.id == id else { return }
        guidance.phase = phase
        withAnimation(.easeInOut(duration: 0.18)) {
            keyboardReturnGuidance = guidance
        }
    }

    private func dismissKeyboardReturnGuidance(after delay: Duration, id: UUID) async {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, keyboardReturnGuidance?.id == id else { return }
        withAnimation(.easeIn(duration: 0.18)) {
            keyboardReturnGuidance = nil
        }
    }

    private func consumePendingWidgetRecordIfNeeded() {
        guard pendingWidgetRecord else { return }
        pendingWidgetRecord = false
        guard AppConstants.lockScreenQuickRecordEnabled else { return }

        let requestedFlowID = AppConstants.sharedDefaults?.string(forKey: AppConstants.pendingWidgetRecordFlowIdKey)
        AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingWidgetRecordFlowIdKey)
        let flowID: String = requestedFlowID.flatMap { requested in
            guard let flow = CapturePresetStore.flow(id: requested), flow.isEnabled else { return nil }
            selectFlow(flow)
            return flow.id
        } ?? selectedFlow.id

        lastStartedRecordingMode = .preset
        persistentRecorder.lastTranscriptionResult = nil
        _ = persistentRecorder.startOneShotInAppSegment(
            flowId: flowID,
            completionMode: .runVox(flowID: flowID)
        )
    }

    private func handleRecorderNeedsUnlock(_ needsUnlock: Bool) {
        guard needsUnlock else { return }
        persistentRecorder.needsUnlock = false
        usageTracker.reload()
        if usageTracker.isAtLimit { presentPaywall(context: .limit) }
    }

    private func dismissExportToastAfterDelay() async {
        guard fileExportToast != nil else { return }
        try? await Task.sleep(for: .seconds(3.5))
        guard !Task.isCancelled else { return }
        fileExportToast = nil
    }

    private func handleFileExportEvent(_ event: FileExportEvent?) {
        guard let event else { return }
        switch event.result {
        case .success(let url):
            fileExportToast = FileExportToast(url: url)
        case .failure(let message):
            fileExportToast = nil
            persistentRecorder.lastError = String(localized: "Your transcript was saved locally, but file export failed. \(message)")
        }
    }

    private func handleTranscribingChange(_ isTranscribing: Bool) {
        guard !isTranscribing else { return }
        if lastStartedRecordingMode == .draft, persistentRecorder.lastTranscriptionResult != nil {
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Transcript added to Capture"))
        }
        watchRecordingPipeline.resume()
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

    private func formatRecordingDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func captureTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func payloadIcon(_ payload: CapturePayload) -> String {
        switch payload {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .audio, .retainedAudio: return "waveform"
        case .image: return "photo"
        case .file: return "doc"
        case .scannedDocument: return "doc.viewfinder"
        case .sketch: return "pencil.tip"
        }
    }

    private func payloadLabel(_ payload: CapturePayload) -> String {
        switch payload {
        case .text(let value): return value
        case .url(let url, let title): return title ?? url.absoluteString
        case .audio(let asset, _), .retainedAudio(let asset, _), .image(let asset, _), .file(let asset):
            return asset.originalFilename
        case .scannedDocument(let pages, _, _):
            return String(localized: "Scan · \(pages.count) page(s)")
        case .sketch: return String(localized: "Sketch")
        }
    }
}

private struct BlinkingCaptureCaret: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 21
    @State private var isVisible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(colorScheme == .dark ? Color.white : Color.black)
            .frame(width: 2, height: height)
            .opacity(accessibilityReduceMotion || isVisible ? 1 : 0)
            .task(id: accessibilityReduceMotion) {
                isVisible = true
                guard !accessibilityReduceMotion else { return }

                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(530))
                    guard !Task.isCancelled else { return }
                    isVisible.toggle()
                }
            }
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
            HStack(spacing: Geist.Spacing.two) {
                Image(systemName: "checkmark.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Ready")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                    Text(fileName)
                        .font(Geist.body())
                        .foregroundStyle(Geist.text)
                        .lineLimit(1)
                }
                Spacer()
                Text("Open File")
                    .font(Geist.label())
            }
            .padding(Geist.Spacing.three)
            .background(Geist.Palette.background100)
            .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
