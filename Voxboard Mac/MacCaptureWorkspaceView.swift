import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

private enum MacCaptureRecordingMode: String, CaseIterable, Identifiable {
    case draft
    case preset

    var id: Self { self }
}

/// Capture-first Mac companion surface. It uses the same durable draft and
/// delivery model as iOS while adapting input, editing, and window behavior to
/// AppKit.
struct MacCaptureWorkspaceView: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @Bindable var recorder: MacRecorder
    let windowToken: String
    let windowCoordinator: MacWindowCoordinator
    let openHistory: () -> Void
    let openSettings: () -> Void

    @Environment(ModelManager.self) private var modelManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(MacStoreManager.self) private var storeManager
    @Environment(TranscriptStore.self) private var transcriptStore
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @State private var flows = CapturePresetStore.loadFlows()
    @State private var showsRouteInspector = false
    @State private var recordingMode: MacCaptureRecordingMode = .preset
    @State private var attachRecordingAudio = false
    @State private var showsLinkPrompt = false
    @State private var showsCamera = false
    @State private var showsSketch = false
    @State private var showsInternalLinkPrompt = false
    @State private var showsDueDate = false
    @State private var showsPaywall = false
    @State private var linkText = ""
    @State private var internalLinkText = ""
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var composerIsFocused = false
    @State private var composerController = MacMarkdownComposerController()
    @State private var isProcessingAttachments = false
    @State private var isDropTargeted = false
    @State private var showsSentToast = false
    @State private var lastRevealedReceiptURL: URL?
    @State private var inspirationQuote = InspirationQuote.fallback
    @State private var hasLoadedInspirationQuote = false

    var body: some View {
        ZStack(alignment: .top) {
            Geist.Palette.background100.ignoresSafeArea()

            VStack(spacing: 0) {
                captureHeader
                GeistDivider()

                if viewModel.selectedDestination == nil && !isLocalizationScreenshot {
                    destinationSetupBanner
                    GeistDivider()
                }

                composer
                    .layoutPriority(1)

                if !viewModel.draft.additionalPayloads.isEmpty {
                    attachmentStrip
                    GeistDivider()
                }

                if recorder.isRecording || recorder.isTranscribing || recorder.isExporting {
                    recordingStatusBar
                    GeistDivider()
                }

                captureActionBar
                GeistDivider()
                markdownToolbar
            }

            if let message = displayedError {
                errorBanner(message)
                    .padding(.horizontal, Geist.Spacing.four)
                    .padding(.top, 70)
                    .frame(maxWidth: 720)
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
                    .padding(.top, 74)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(5)
            }
        }
        .navigationTitle("Capture")
        .task {
            await viewModel.load()
            reloadFlows()
            consumeRequestedInput()
            transcriptStore.reload()
            await loadInspirationQuoteIfNeeded()
            if viewModel.needsCaptureUnlock {
                viewModel.needsCaptureUnlock = false
                showsPaywall = !usageTracker.hasUnlocked
            }
        }
        .onAppear {
            windowCoordinator.captureWorkspaceReady(token: windowToken)
            reloadFlows()
            DispatchQueue.main.async { composerController.focus() }
        }
        .onChange(of: viewModel.requestedInput) { _, _ in
            consumeRequestedInput()
        }
        .onChange(of: viewModel.draft.text) { _, _ in
            if !viewModel.hasLiveRecordedTranscriptPreview {
                viewModel.scheduleDraftSave()
            }
        }
        .onChange(of: viewModel.lastReceipt) { _, receipt in
            guard let receipt else { return }
            usageTracker.reload()
            lastRevealedReceiptURL = receipt.noteURL
            Task { await presentSentToast() }
        }
        .onChange(of: viewModel.needsCaptureUnlock) { _, needsUnlock in
            guard needsUnlock else { return }
            viewModel.needsCaptureUnlock = false
            usageTracker.reload()
            showsPaywall = !usageTracker.hasUnlocked
        }
        .onChange(of: recorder.needsUnlock) { _, needsUnlock in
            guard needsUnlock else { return }
            recorder.needsUnlock = false
            showsPaywall = true
        }
        .sheet(isPresented: $showsRouteInspector, onDismiss: reloadFlows) {
            MacCaptureRouteInspector(viewModel: viewModel)
        }
        .sheet(isPresented: $showsCamera) {
            MacCameraCaptureView(onCapture: stageCameraImage)
        }
        .sheet(isPresented: $showsSketch) {
            MacSketchEditor(onSave: stageSketch)
        }
        .sheet(isPresented: $showsDueDate) {
            MacCaptureDueDateSheet(onInsert: insertDueDate)
        }
        .sheet(isPresented: $showsPaywall) {
            MacPaywallView(context: .captureLimit)
                .environment(usageTracker)
                .environment(storeManager)
        }
        .alert("Capture Link", isPresented: $showsLinkPrompt) {
            TextField("https://example.com", text: $linkText)
            Button("Cancel", role: .cancel) { linkText = "" }
            Button("Add") { addLink() }
        } message: {
            Text("The link remains in the durable Capture draft until it is sent.")
        }
        .alert("Internal Link", isPresented: $showsInternalLinkPrompt) {
            TextField("Projects/Vox", text: $internalLinkText)
            Button("Cancel", role: .cancel) { internalLinkText = "" }
            Button("Insert") { insertInternalLink() }
        } message: {
            Text("Enter a note name or vault-relative path. Vox.md inserts an Obsidian wiki link.")
        }
        .confirmationDialog(
            "Location",
            isPresented: Binding(
                get: { viewModel.locationDecision != nil },
                set: { if !$0 { Task { await viewModel.cancelUnavailableLocation() } } }
            ),
            titleVisibility: .visible
        ) {
            Button("Retry") { Task { await viewModel.retryUnavailableLocation() } }
            Button("Send Without Location") {
                Task { await viewModel.sendWithoutUnavailableLocation(alwaysForPreset: false) }
            }
            Button("Always Send Without Location for This Preset") {
                Task { await viewModel.sendWithoutUnavailableLocation(alwaysForPreset: true) }
            }
            Button("Cancel", role: .cancel) {
                Task { await viewModel.cancelUnavailableLocation() }
            }
        } message: {
            Text("Vox.md could not get an origin-time location. Your Capture draft is preserved.")
        }
        .confirmationDialog(
            inboxLocationDecisionTitle,
            isPresented: Binding(
                get: { viewModel.inboxLocationDecision != nil },
                set: { _ in }
            ),
            titleVisibility: .visible
        ) {
            Button("Send Without Location") {
                Task { await viewModel.sendInboxRequestWithoutLocation() }
            }
            Button("Always Send Without Location for This Preset") {
                Task { await viewModel.sendInboxRequestWithoutLocation(alwaysForPreset: true) }
            }
            Button("Cancel and Discard Capture", role: .destructive) {
                Task { await viewModel.discardInboxLocationRequest() }
            }
        } message: {
            Text(inboxLocationDecisionMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macShowCapture)) { notification in
            guard notification.object == nil || (notification.object as? String) == windowToken else { return }
            DispatchQueue.main.async { composerController.focus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macChooseCaptureFiles)) { notification in
            guard notification.object == nil || (notification.object as? String) == windowToken else { return }
            chooseFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macClearCaptureDraft)) { notification in
            guard notification.object == nil || (notification.object as? String) == windowToken else { return }
            Task {
                await viewModel.clearDraft()
                composerController.focus()
            }
        }
        .onDisappear {
            windowCoordinator.captureWorkspaceNotReady(token: windowToken)
            Task { await viewModel.saveDraftNow() }
        }
    }

    private var captureHeader: some View {
        HStack(spacing: Geist.Spacing.three) {
            GeistStatusBadge(
                label: recorder.isRecording
                    ? "Recording"
                    : recorder.isTranscribing
                        ? "Transcribing"
                        : recorder.isExporting
                            ? "Finishing Export"
                            : "Draft Saved Locally",
                isActive: recorder.isRecording || recorder.isTranscribing || recorder.isExporting
            )

            Menu {
                ForEach(enabledFlows) { flow in
                    Button {
                        selectFlow(flow)
                    } label: {
                        Label(flow.displayName, systemImage: safeSymbol(flow.symbolName))
                    }
                }
            } label: {
                Label(selectedFlow.displayName, systemImage: safeSymbol(selectedFlow.symbolName))
                    .font(Geist.label())
                    .lineLimit(1)
                    .padding(.horizontal, Geist.Spacing.three)
                    .frame(height: Geist.ControlHeight.medium)
                    .background(Geist.Palette.gray100)
                    .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(recorder.isRecording || recorder.isTranscribing || recorder.isExporting)
            .accessibilityLabel("Capture Preset \(selectedFlow.displayName)")
            .accessibilityIdentifier("mac_capture_preset_selector")

            if selectedFlow.locationPolicy.isEnabled {
                HStack(spacing: Geist.Spacing.two) {
                    if viewModel.isResolvingLocation || recorder.isResolvingLocation {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding Location…")
                    } else {
                        Image(systemName: "location.fill")
                        Text("Current Location On")
                    }
                }
                .font(Geist.caption())
                .foregroundStyle(
                    viewModel.isResolvingLocation || recorder.isResolvingLocation ? Geist.text : Geist.muted
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    (viewModel.isResolvingLocation || recorder.isResolvingLocation
                        ? String(localized: "Finding Location…")
                        : String(localized: "Current Location On"))
                    + " " + selectedFlow.displayName
                )
                .accessibilityIdentifier(
                    viewModel.isResolvingLocation || recorder.isResolvingLocation
                        ? "mac_capture_finding_preset_location"
                        : "mac_capture_active_preset_location"
                )
            }

            Button {
                composerController.dismissFocus()
                showsRouteInspector = true
            } label: {
                HStack(spacing: Geist.Spacing.two) {
                    Image(systemName: viewModel.hasAnyRouteOverride ? "arrow.triangle.branch" : "tray.full")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(routeLabel)
                            .font(Geist.label())
                            .lineLimit(1)
                        Text(viewModel.resolvedDestinationPreview
                             ?? String(localized: "Choose where this Capture writes Markdown"))
                            .font(Geist.caption(.caption2))
                            .foregroundStyle(Geist.muted)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(Geist.text)
                .padding(.horizontal, Geist.Spacing.three)
                .frame(height: Geist.ControlHeight.medium)
                .background(Geist.Palette.gray100)
                .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac_capture_route")

            Spacer(minLength: Geist.Spacing.four)

            if !usageTracker.hasUnlocked {
                Button {
                    showsPaywall = true
                } label: {
                    Text(usageTracker.isCaptureAtLimit
                         ? "Unlock Capture"
                         : "\(usageTracker.capturesRemaining) captures · \(String(format: "%.1f", usageTracker.minutesRemaining)) min")
                        .font(Geist.mono(.caption2, medium: true))
                        .foregroundStyle(usageTracker.isCaptureAtLimit ? Geist.error : Geist.muted)
                }
                .buttonStyle(.plain)
            }

            Button(action: openHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("History")
            .accessibilityLabel("History")

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Geist.Spacing.four)
        .padding(.vertical, Geist.Spacing.three)
        .background(Geist.Palette.background100)
    }

    private var destinationSetupBanner: some View {
        Button {
            composerController.dismissFocus()
            showsRouteInspector = true
        } label: {
            HStack(spacing: Geist.Spacing.three) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Destination Not Configured")
                        .font(Geist.label())
                    Text("Choose a vault or folder and define where this Capture Preset writes Markdown.")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
                Spacer()
                Text("Set Up")
                    .font(Geist.label())
                Image(systemName: "chevron.right")
            }
            .padding(.horizontal, Geist.Spacing.four)
            .frame(minHeight: 54)
            .foregroundStyle(Geist.text)
            .background(Geist.Palette.amber100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac_capture_destination_banner")
    }

    private var composer: some View {
        MacMarkdownComposerTextView(
            text: $viewModel.draft.text,
            selection: $composerSelection,
            isFocused: $composerIsFocused,
            controller: composerController
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Geist.Palette.blue100 : Geist.Palette.background100)
        .overlay(alignment: .center) {
            if !viewModel.draft.hasCaptureContent {
                emptyComposerPrompt
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous)
                    .stroke(Geist.focus, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await stageURLs(urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var emptyComposerPrompt: some View {
        VStack(spacing: Geist.Spacing.three) {
            if !selectedFlow.displayCapturePrompt.isEmpty {
                Image(systemName: safeSymbol(selectedFlow.symbolName))
                    .font(.system(size: 26, weight: .medium))
                Text(selectedFlow.displayCapturePrompt)
                    .font(Geist.body(.title3))
                Text(selectedFlow.displayName)
                    .font(Geist.caption())
            } else {
                Text(verbatim: "“\(inspirationQuote.text)”")
                    .font(Geist.body(.title3))
                Text(verbatim: "— \(inspirationQuote.author)")
                    .font(Geist.caption())
            }
            Text("Type Markdown, dictate, paste, or drop files anywhere in this window.")
                .font(Geist.caption())
        }
        .foregroundStyle(Geist.faint)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 560)
        .padding(Geist.Spacing.six)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Geist.Spacing.two) {
                ForEach(Array(viewModel.draft.additionalPayloads.enumerated()), id: \.offset) { index, payload in
                    HStack(spacing: Geist.Spacing.two) {
                        Image(systemName: payloadIcon(payload))
                        Text(payloadLabel(payload))
                            .lineLimit(1)
                        Button {
                            Task { await viewModel.removePayload(at: index) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(payloadLabel(payload))")
                    }
                    .font(Geist.caption())
                    .foregroundStyle(Geist.text)
                    .padding(.horizontal, Geist.Spacing.three)
                    .frame(height: 34)
                    .background(Geist.Palette.gray100)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, Geist.Spacing.three)
            .padding(.vertical, Geist.Spacing.two)
        }
        .background(Geist.Palette.background100)
        .accessibilityLabel("Capture attachments")
    }

    private var recordingStatusBar: some View {
        HStack(spacing: Geist.Spacing.three) {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform.badge.magnifyingglass")
                .foregroundStyle(recorder.isRecording ? Geist.error : Geist.focus)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    recorder.isRecording
                        ? "Recording \(formatDuration(recorder.recordingDuration))"
                        : recorder.isTranscribing
                            ? "Transcribing on this Mac"
                            : "Finishing the Capture export"
                )
                    .font(Geist.label())
                Text(recorder.isExporting
                     ? "The transcript is saved locally while its note and requested audio finish exporting."
                     : recordingMode == .draft
                         ? "The on-device transcript will be added to this durable draft."
                         : "The recording will be processed and sent with \(selectedFlow.displayName).")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
            }
            Spacer()
            if recorder.isRecording {
                Button {
                    recorder.stopAndTranscribe(modelManager: modelManager, flowId: selectedFlow.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(GeistButtonStyle(variant: .destructive, size: .small))
                .fixedSize()
            } else if recorder.isTranscribing,
                      let progress = recorder.transcriptionProgress,
                      let fraction = progress.exactFractionCompleted,
                      let percent = progress.formattedWholePercentCompleted {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: fraction)
                        .frame(width: 110)
                    Text("\(percent) complete")
                        .font(Geist.mono(.caption2))
                        .foregroundStyle(Geist.muted)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Transcription \(percent) complete")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, Geist.Spacing.four)
        .padding(.vertical, Geist.Spacing.three)
        .background(Geist.Palette.background200)
    }

    private var captureActionBar: some View {
        HStack(spacing: Geist.Spacing.two) {
            Button(action: openHistory) {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(GeistButtonStyle(variant: .tertiary, size: .small))
            .fixedSize()

            if let lastRevealedReceiptURL {
                Button {
                    revealInFinder(lastRevealedReceiptURL)
                } label: {
                    Label("Reveal Last Capture", systemImage: "folder")
                }
                .buttonStyle(GeistButtonStyle(variant: .tertiary, size: .small))
                .fixedSize()
            }

            Spacer()

            Picker("Recording result", selection: $recordingMode) {
                Text("Add to Draft").tag(MacCaptureRecordingMode.draft)
                Text("Send Immediately").tag(MacCaptureRecordingMode.preset)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .disabled(recorder.isRecording || recorder.isTranscribing || recorder.isExporting)
            .accessibilityIdentifier("mac_capture_recording_mode")

            if recordingMode == .draft {
                Toggle("Audio", isOn: $attachRecordingAudio)
                    .toggleStyle(.checkbox)
                    .font(Geist.caption())
                    .disabled(recorder.isRecording || recorder.isTranscribing || recorder.isExporting)
                    .help("Attach the recording to this Capture draft")
            }

            Button {
                if recorder.isRecording {
                    recorder.stopAndTranscribe(modelManager: modelManager, flowId: selectedFlow.id)
                } else {
                    startRecording()
                }
            } label: {
                Label(
                    recorder.isRecording ? String(localized: "Stop") : String(localized: "Record"),
                    systemImage: recorder.isRecording ? "stop.fill" : "mic"
                )
            }
            .buttonStyle(GeistButtonStyle(
                variant: recorder.isRecording ? .destructive : .secondary,
                size: .small
            ))
            .fixedSize()
            .disabled(recorder.isTranscribing || recorder.isExporting)
            .accessibilityIdentifier("mac_capture_record")

            Button {
                sendCapture()
            } label: {
                Label(
                    captureAllowanceBlocked
                        ? String(localized: "Unlock")
                        : (viewModel.isSubmitting ? String(localized: "Sending…") : String(localized: "Send Capture")),
                    systemImage: captureAllowanceBlocked ? "lock.fill" : "arrow.up"
                )
            }
            .buttonStyle(GeistButtonStyle(
                variant: captureAllowanceBlocked ? .destructive : .primary,
                size: .small
            ))
            .fixedSize()
            .disabled(!viewModel.canSubmit || isProcessingAttachments || recorder.isRecording || recorder.isTranscribing)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier("mac_quick_capture_submit")
        }
        .padding(.horizontal, Geist.Spacing.three)
        .padding(.vertical, Geist.Spacing.two)
        .background(Geist.Palette.background200)
    }

    private var markdownToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Menu {
                    Button("Images or Screenshots…", systemImage: "photo") { chooseImages() }
                    Button("Take Photo…", systemImage: "camera") { showsCamera = true }
                    Button("Import Scan or PDF…", systemImage: "doc.viewfinder") { chooseScan() }
                    Button("Sketch…", systemImage: "pencil.tip") { showsSketch = true }
                    Button("Files…", systemImage: "paperclip") { chooseFiles() }
                    Button("Audio Attachment…", systemImage: "waveform") { chooseAudio() }
                    Button("Transcribe Audio or Video…", systemImage: "waveform.badge.plus") {
                        importAudioForTranscription()
                    }
                    Divider()
                    Button("Web Link…", systemImage: "link") { showsLinkPrompt = true }
                    Button("Paste", systemImage: "clipboard") { pasteIntoCapture() }
                } label: {
                    toolbarLabel("Add attachment", icon: isProcessingAttachments ? "hourglass" : "plus")
                }
                .disabled(isProcessingAttachments)

                toolbarButton("Undo", icon: "arrow.uturn.backward") { composerController.undo() }

                Menu {
                    Button("Bold") { applyComposerCommand(.toggleBold) }
                        .keyboardShortcut("b", modifiers: [.command])
                    Button("Italic") { applyComposerCommand(.toggleItalic) }
                        .keyboardShortcut("i", modifiers: [.command])
                    Button("Hashtag") { applyComposerCommand(.insertHashtag) }
                    Divider()
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") { applyComposerCommand(.heading(level: level)) }
                    }
                } label: {
                    toolbarLabel("Format Markdown", icon: "textformat")
                }

                toolbarButton("Markdown link", icon: "link") {
                    applyComposerCommand(.markdownLink())
                }
                toolbarButton("Internal link", text: "[[") {
                    showsInternalLinkPrompt = true
                }
                toolbarButton("Due date", icon: "alarm") {
                    showsDueDate = true
                }
                toolbarButton("Checklist", icon: "checkmark.square") {
                    applyComposerCommand(.taskCheckbox)
                }
                toolbarButton("Bullet list", icon: "list.bullet") {
                    applyComposerCommand(.bullet)
                }
                toolbarButton("Timestamp", icon: "clock") {
                    applyComposerCommand(.replaceSelection(with: insertionFormatter.currentTimestamp()))
                }
                toolbarButton("Date", icon: "calendar") {
                    applyComposerCommand(.replaceSelection(with: captureDateString()))
                }

                Menu {
                    Button("Lowercase") { applyComposerCommand(.lowercase) }
                    Button("Uppercase") { applyComposerCommand(.uppercase) }
                    Button("Sentence case") { applyComposerCommand(.sentenceCase) }
                    Button("Capitalize Words") { applyComposerCommand(.capitalizeWords) }
                    Button("Slugify") { applyComposerCommand(.slugify) }
                } label: {
                    toolbarLabel("Change text case", text: "Abc")
                }
            }
            .padding(.horizontal, Geist.Spacing.two)
            .padding(.vertical, Geist.Spacing.one)
        }
        .frame(height: 48)
        .background(Geist.Palette.background100)
        .accessibilityLabel("Markdown and Capture tools")
    }

    private func toolbarButton(
        _ label: LocalizedStringResource,
        icon: String? = nil,
        text: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarLabel(label, icon: icon, text: text)
        }
        .buttonStyle(.plain)
    }

    private func toolbarLabel(_ label: LocalizedStringResource, icon: String? = nil, text: String? = nil) -> some View {
        Group {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
            } else {
                Text(text ?? "")
                    .font(Geist.mono(.footnote, medium: true))
            }
        }
        .foregroundStyle(Geist.text)
        .frame(width: 38, height: 38)
        .contentShape(Rectangle())
        .help(String(localized: label))
        .accessibilityLabel(Text(label))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Geist.Spacing.three) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Geist.error)
            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                Text(message)
                    .font(Geist.caption())
                if viewModel.failedInboxCount > 0 {
                    Button("Retry queued captures") {
                        Task { await viewModel.retryFailedInbox() }
                    }
                    .font(Geist.caption())
                }
                if viewModel.errorMessage == nil,
                   let recoveryURL = recorder.lastRecoveryAudioURL {
                    Button("Reveal preserved recording") {
                        NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
                    }
                    .font(Geist.caption())
                }
            }
            Spacer()
            Button {
                if viewModel.errorMessage != nil {
                    viewModel.errorMessage = nil
                } else {
                    recorder.lastError = nil
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(Geist.Spacing.three)
        .foregroundStyle(Geist.text)
        .background(Geist.Palette.red100)
        .overlay {
            RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous)
                .stroke(Geist.Palette.red400, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
    }

    private func revealInFinder(_ url: URL) {
        let rootURL = viewModel.selectedRootURL()
        let didAccess = rootURL?.startAccessingSecurityScopedResource() ?? false
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if didAccess { rootURL?.stopAccessingSecurityScopedResource() }
    }

    private func stageCameraImage(_ imageData: Data) {
        Task {
            isProcessingAttachments = true
            await viewModel.stageImage(
                data: imageData,
                filename: "camera-photo.jpg",
                contentTypeIdentifier: UTType.jpeg.identifier,
                altText: String(localized: "Camera photo")
            )
            isProcessingAttachments = false
            composerController.focus()
        }
    }

    private func stageSketch(_ drawingData: Data, _ previewData: Data) {
        Task {
            isProcessingAttachments = true
            await viewModel.stageSketch(
                drawingData: drawingData,
                previewData: previewData,
                altText: String(localized: "Sketch created on Mac"),
                drawingFilename: "sketch.voxsketch",
                drawingContentTypeIdentifier: "application/vnd.voxmd.sketch+json"
            )
            isProcessingAttachments = false
            composerController.focus()
        }
    }

    private func insertDueDate(_ date: Date, _ includesTime: Bool) {
        let token = insertionFormatter.dueDateToken(for: date, includeTime: includesTime)
        applyComposerCommand(.replaceSelection(with: token))
    }

    private var displayedError: String? {
        if isLocalizationScreenshot { return nil }
        if let message = viewModel.errorMessage { return message }
        return recorder.lastError
    }

    private var isLocalizationScreenshot: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--localization-screenshot")
        #else
        return false
        #endif
    }

    private var enabledFlows: [CapturePreset] {
        let enabled = flows.filter(\.isEnabled)
        return enabled.isEmpty ? CapturePresetStore.defaultFlows : enabled
    }

    private var selectedFlow: CapturePreset {
        if let id = viewModel.draft.voxID,
           let match = enabledFlows.first(where: { $0.id == id }) {
            return match
        }
        return enabledFlows.first(where: { $0.id == CapturePresetStore.selectedFlowId() })
            ?? enabledFlows[0]
    }

    private var inboxLocationDecisionTitle: String {
        guard let decision = viewModel.inboxLocationDecision else {
            return String(localized: "Send Capture Without Location?")
        }
        let preset = decision.presetName ?? String(localized: "Unknown Preset")
        return String(localized: "Location Needed for \(preset)")
    }

    private var inboxLocationDecisionMessage: String {
        guard let decision = viewModel.inboxLocationDecision else { return "" }
        let preset = decision.presetName ?? String(localized: "Unknown Preset")
        return String(localized: "Send Capture Without Location?")
            + " " + preset + ". "
            + String(localized: "Location is unavailable. Open Vox.md to send this exact Capture without location or discard it.")
    }

    private var routeLabel: String {
        if let override = viewModel.draft.relativeNotePathOverride {
            return URL(fileURLWithPath: override).deletingPathExtension().lastPathComponent
        }
        return viewModel.selectedDestination?.rootName ?? String(localized: "Set up destination")
    }

    private var insertionFormatter: CaptureInsertionFormatter {
        CaptureInsertionFormatter(calendar: calendar, locale: locale, timeZone: timeZone)
    }

    private func reloadFlows() {
        flows = CapturePresetStore.loadFlows()
        viewModel.refreshVoxProfiles()
        Task { await viewModel.refreshLibrary() }
    }

    private func consumeRequestedInput() {
        guard let requestedInput = viewModel.requestedInput else { return }
        viewModel.requestedInput = nil
        switch requestedInput {
        case .photos, .screenshots: chooseImages()
        case .camera: showsCamera = true
        case .files: chooseFiles()
        case .scan: chooseScan()
        case .sketch: showsSketch = true
        case .link: showsLinkPrompt = true
        case .voice: startRecording()
        }
    }

    private func selectFlow(_ flow: CapturePreset) {
        viewModel.selectVox(flow.id)
        CapturePresetStore.selectFlow(id: flow.id)
        reloadFlows()
    }

    private var captureAllowanceBlocked: Bool {
        viewModel.draft.deliveryKind == .standard && usageTracker.isCaptureAtLimit
    }

    private func sendCapture() {
        if captureAllowanceBlocked {
            showsPaywall = true
            return
        }
        Task { await viewModel.submit() }
    }

    private func startRecording() {
        guard !usageTracker.isAtLimit else {
            showsPaywall = true
            return
        }
        Task { @MainActor in
            let granted = await AudioRecorder.requestMicrophonePermission()
            guard granted else {
                recorder.lastError = String(localized: "Enable microphone access in System Settings to record audio.")
                return
            }
            recorder.startRecording(
                modelManager: modelManager,
                flowId: selectedFlow.id,
                completionMode: selectedRecordingCompletionMode
            )
        }
    }

    private var selectedRecordingCompletionMode: MacRecordingCompletionMode {
        switch recordingMode {
        case .draft:
            return .captureDraft(attachAudio: attachRecordingAudio)
        case .preset:
            return .runPreset(flow: selectedFlow)
        }
    }

    private func applyComposerCommand(_ command: CaptureComposerCommand) {
        let result = CaptureComposerTextEditor().applying(
            command,
            to: composerController.text,
            selection: CaptureTextSelection(
                location: composerController.selection.location,
                length: composerController.selection.length
            )
        )
        composerController.replaceAll(
            with: result.text,
            selection: NSRange(location: result.selection.location, length: result.selection.length)
        )
        composerIsFocused = true
        composerController.focus()
    }

    private func chooseImages() {
        chooseURLs(
            title: String(localized: "Add Images to Capture"),
            contentTypes: [.image],
            allowsMultipleSelection: true
        )
    }

    private func chooseScan() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Scan or PDF")
        panel.prompt = String(localized: "Add Scan")
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        Task {
            isProcessingAttachments = true
            defer {
                isProcessingAttachments = false
                composerController.focus()
            }
            do {
                var budget = CaptureInputBudget()
                try budget.reserveSharedItems(panel.urls.count)
                var imageURLs: [URL] = []
                var otherURLs: [URL] = []
                for url in panel.urls {
                    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                        ?? UTType(filenameExtension: url.pathExtension)
                        ?? .data
                    if type.conforms(to: .image) {
                        imageURLs.append(url)
                    } else {
                        otherURLs.append(url)
                    }
                }
                if !imageURLs.isEmpty {
                    let scan = try await MacDocumentScanProcessor.process(imageURLs: imageURLs)
                    await viewModel.stageScan(
                        pageImages: scan.pageImages,
                        pdfData: scan.pdfData,
                        extractedText: scan.extractedText
                    )
                }
                if !otherURLs.isEmpty {
                    await stageURLs(otherURLs)
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func chooseFiles() {
        chooseURLs(
            title: String(localized: "Add Files to Capture"),
            contentTypes: [.data],
            allowsMultipleSelection: true
        )
    }

    private func chooseAudio() {
        chooseURLs(
            title: String(localized: "Add Audio to Capture"),
            contentTypes: [.audio],
            allowsMultipleSelection: true
        )
    }

    private func importAudioForTranscription() {
        guard !usageTracker.isAtLimit else {
            showsPaywall = true
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Transcribe Audio or Video")
        panel.prompt = String(localized: "Transcribe")
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recorder.importAudioFile(
            from: url,
            modelManager: modelManager,
            flowId: selectedFlow.id,
            completionMode: selectedRecordingCompletionMode
        )
    }

    private func chooseURLs(
        title: String,
        contentTypes: [UTType],
        allowsMultipleSelection: Bool
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = String(localized: "Add")
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        Task { await stageURLs(panel.urls) }
    }

    private func stageURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isProcessingAttachments = true
        defer {
            isProcessingAttachments = false
            composerController.focus()
        }
        do {
            var budget = CaptureInputBudget()
            try budget.reserveSharedItems(urls.count)
            for url in urls {
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                    ?? UTType(filenameExtension: url.pathExtension)
                    ?? .data
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

    private func pasteIntoCapture() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            Task { await stageURLs(urls) }
            return
        }

        if let data = pasteboard.data(forType: .png) {
            Task {
                isProcessingAttachments = true
                await viewModel.stageImage(
                    data: data,
                    filename: "pasted-image-\(UUID().uuidString.lowercased()).png",
                    contentTypeIdentifier: UTType.png.identifier,
                    altText: String(localized: "Pasted image")
                )
                isProcessingAttachments = false
            }
            return
        }

        if let tiff = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiff),
           let png = pngData(from: image) {
            Task {
                isProcessingAttachments = true
                await viewModel.stageImage(
                    data: png,
                    filename: "pasted-image-\(UUID().uuidString.lowercased()).png",
                    contentTypeIdentifier: UTType.png.identifier,
                    altText: String(localized: "Pasted image")
                )
                isProcessingAttachments = false
            }
            return
        }

        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return }
        if let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            Task { await viewModel.addURL(url) }
        } else {
            composerController.replaceSelection(with: string)
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func addLink() {
        let value = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        linkText = ""
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            viewModel.errorMessage = String(localized: "Enter a complete http:// or https:// link.")
            return
        }
        Task { await viewModel.addURL(url) }
    }

    private func insertInternalLink() {
        let value = internalLinkText
        internalLinkText = ""
        do {
            applyComposerCommand(.replaceSelection(with: try insertionFormatter.wikiLink(for: value)))
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func captureDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func loadInspirationQuoteIfNeeded() async {
        guard !hasLoadedInspirationQuote else { return }
        inspirationQuote = await InspirationQuoteService.shared.nextQuote()
        hasLoadedInspirationQuote = true
    }

    private func presentSentToast() async {
        withAnimation(.easeOut(duration: 0.18)) { showsSentToast = true }
        try? await Task.sleep(for: .seconds(2))
        withAnimation(.easeIn(duration: 0.18)) { showsSentToast = false }
        composerController.focus()
    }

    private func safeSymbol(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "waveform" : value
    }

    private func payloadIcon(_ payload: CapturePayload) -> String {
        switch payload {
        case .text: "text.alignleft"
        case .url: "link"
        case .audio, .retainedAudio: "waveform"
        case .image: "photo"
        case .file: "doc"
        case .scannedDocument: "doc.viewfinder"
        case .sketch: "pencil.tip"
        }
    }

    private func payloadLabel(_ payload: CapturePayload) -> String {
        switch payload {
        case .text(let value): value
        case .url(let url, let title): title ?? url.absoluteString
        case .audio(let asset, _), .retainedAudio(let asset, _), .image(let asset, _), .file(let asset):
            asset.originalFilename
        case .scannedDocument(let pages, _, _): "Scan · \(pages.count) page(s)"
        case .sketch: "Sketch"
        }
    }
}

private struct MacCaptureRouteInspector: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingDestination = false

    var body: some View {
        NavigationStack {
            Form {
                if let preset = viewModel.selectedVoxProfile {
                    Section("Capture Preset") {
                        LabeledContent("Preset") {
                            Label(preset.displayName, systemImage: preset.symbolName)
                        }
                        if let destination = viewModel.selectedPresetDestination {
                            LabeledContent("Vault / Folder", value: destination.rootName)
                            Button("Edit Preset Destination…") {
                                isEditingDestination = true
                            }
                        } else {
                            Text("This Capture Preset needs a destination before it can send Markdown.")
                                .foregroundStyle(.secondary)
                            Button("Set Up Destination…") {
                                isEditingDestination = true
                            }
                            .accessibilityIdentifier("mac_capture_destination_setup")
                        }
                    }
                }

                if viewModel.selectedDestination != nil {
                    Section("Only for this Capture") {
                        Picker("Placement", selection: placementBinding) {
                            Text("Preset Default").tag(PlacementChoice.default)
                            Text("Top").tag(PlacementChoice.top)
                            Text("Bottom").tag(PlacementChoice.bottom)
                        }

                        Picker("Entry Template", selection: $viewModel.draft.entryTemplateID) {
                            Text("Preset Default").tag(UUID?.none)
                            ForEach(viewModel.entryTemplates) { template in
                                Text(template.name).tag(Optional(template.id))
                            }
                        }
                        .onChange(of: viewModel.draft.entryTemplateID) { _, _ in
                            viewModel.scheduleDraftSave()
                        }

                        Button {
                            chooseOneOffNote()
                        } label: {
                            Label(
                                viewModel.draft.relativeNotePathOverride ?? String(localized: "Choose another Markdown note"),
                                systemImage: "doc.text.magnifyingglass"
                            )
                        }

                        if viewModel.hasAnyRouteOverride {
                            Button("Use Preset Defaults", systemImage: "arrow.uturn.backward") {
                                viewModel.useVoxRouteDefaults()
                            }
                        }
                    }

                    if let preview = viewModel.resolvedDestinationPreview {
                        Section("Resolved Note") {
                            Text(preview)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Capture Route")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await viewModel.saveDraftNow() }
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .sheet(isPresented: $isEditingDestination) {
            MacCaptureDestinationEditor(
                existing: viewModel.selectedPresetDestination,
                templates: viewModel.entryTemplates,
                fixedName: viewModel.selectedVoxProfile?.displayName
            ) { destination in
                try await viewModel.saveSelectedPresetDestination(destination)
            }
        }
    }

    private var placementBinding: Binding<PlacementChoice> {
        Binding(
            get: {
                switch viewModel.draft.placementOverride {
                case nil: .default
                case .prepend: .top
                case .append: .bottom
                case .beneathHeading: .default
                }
            },
            set: { choice in
                switch choice {
                case .default: viewModel.setPlacementOverride(nil)
                case .top: viewModel.setPlacementOverride(.prepend)
                case .bottom: viewModel.setPlacementOverride(.append)
                }
            }
        )
    }

    private func chooseOneOffNote() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Markdown Note")
        panel.prompt = String(localized: "Use Note")
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = viewModel.selectedRootURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.setOneOffNote(url: url) }
    }

    private enum PlacementChoice: String, Hashable {
        case `default`, top, bottom
    }
}

private struct MacCaptureDueDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var includesTime = false
    let onInsert: (Date, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.four) {
            Text("Set Due Date")
                .font(Geist.heading(.title2))
            DatePicker(
                "Due date",
                selection: $date,
                displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date]
            )
            Toggle("Include time", isOn: $includesTime)
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                Spacer()
                Button("Insert") {
                    onInsert(date, includesTime)
                    dismiss()
                }
                .buttonStyle(GeistButtonStyle(variant: .primary, size: .small))
            }
        }
        .padding(Geist.Spacing.six)
        .frame(width: 430)
        .background(Geist.Palette.background100)
    }
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
}
