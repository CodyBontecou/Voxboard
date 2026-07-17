import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit
import VoxboardShared

struct QuickCaptureView: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedScreenshots: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsScreenshotPicker = false
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    @State private var showsScanner = false
    @State private var showsSketch = false
    @State private var showsLinkPrompt = false
    @State private var showsRoutePicker = false
    @State private var showsDueDate = false
    @State private var showsInternalLinks = false
    @State private var showsVoice = false
    @State private var linkText = ""
    @State private var isProcessingMedia = false
    @State private var isFindingLocation = false
    @State private var locationRequestTask: Task<Void, Never>?
    @State private var showsSentToast = false
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var composerIsFocused = false
    @State private var composerController = MarkdownComposerController()
    @State private var locationService = CaptureLocationService()
    @State private var voiceSession: QuickCaptureVoiceSession

    init(
        viewModel: QuickCaptureViewModel,
        microphoneIsBusy: @escaping () -> Bool = { false }
    ) {
        self.viewModel = viewModel
        _voiceSession = State(initialValue: QuickCaptureVoiceSession(
            microphoneIsBusy: microphoneIsBusy,
            stageRecording: { [weak viewModel] url, transcript in
                await viewModel?.stageVoiceRecording(at: url, transcript: transcript)
            },
            updateRecording: { [weak viewModel] asset, transcript in
                await viewModel?.updateStagedVoiceRecording(asset, transcript: transcript) ?? false
            },
            removeRecording: { [weak viewModel] asset in
                await viewModel?.removeStagedVoiceRecording(asset) ?? false
            }
        ))
    }

    var body: some View {
        presentedContent
    }

    private var captureContent: some View {
        ZStack(alignment: .top) {
            Brutal.bg.ignoresSafeArea()
            BrutalGridBackground()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                if viewModel.destinations.isEmpty {
                    emptyDestinationBanner
                    BrutalDivider()
                }

                composer
                    .layoutPriority(1)

                if !viewModel.draft.additionalPayloads.isEmpty {
                    attachmentStrip
                    BrutalDivider()
                }

                routeRow
                BrutalDivider()
                primaryActionRow
                CaptureEditorToolbar(
                    command: handleToolbarCommand,
                    showDueDate: { showsDueDate = true },
                    insertLocation: insertCurrentLocation,
                    showSketch: { showsSketch = true },
                    showScan: { showsScanner = VNDocumentCameraViewController.isSupported },
                    dismissKeyboard: { composerController.dismissKeyboard() },
                    isFindingLocation: isFindingLocation
                )
            }

            if let message = viewModel.errorMessage {
                errorBanner(message)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }

            if showsSentToast {
                Text("Sent")
                    .font(Brutal.label())
                    .foregroundStyle(Brutal.bg)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Brutal.text)
                    .overlay(Rectangle().stroke(Brutal.bg, lineWidth: 1))
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(4)
                    .accessibilityIdentifier("capture_sent_toast")
            }
        }
        .navigationTitle("CAPTURE")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    CaptureHistoryView(viewModel: viewModel)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Recent captures")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CaptureDestinationLibraryView(viewModel: viewModel)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "tray")
                        if viewModel.failedInboxCount > 0 {
                            Text("\(min(viewModel.failedInboxCount, 9))")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Brutal.bg)
                                .frame(width: 14, height: 14)
                                .background(Brutal.error)
                                .clipShape(Circle())
                                .offset(x: 7, y: -6)
                        }
                    }
                }
                .accessibilityLabel(
                    viewModel.failedInboxCount > 0
                        ? "Manage capture routes, \(viewModel.failedInboxCount) deliveries need attention"
                        : "Manage capture routes"
                )
            }
        }
        .toolbarBackground(Brutal.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var lifecycleContent: some View {
        captureContent
        .task { await loadAndPresentRequestedInput() }
        .onChange(of: viewModel.draft.text) { _, _ in viewModel.scheduleDraftSave() }
        .onChange(of: viewModel.draft.destinationID) { _, _ in viewModel.scheduleDraftSave() }
        .onChange(of: viewModel.draft.entryTemplateID) { _, _ in viewModel.scheduleDraftSave() }
        .onChange(of: viewModel.draft.placementOverride) { _, _ in viewModel.scheduleDraftSave() }
        .onChange(of: viewModel.draft.relativeNotePathOverride) { _, _ in viewModel.scheduleDraftSave() }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .onChange(of: viewModel.lastReceipt) { _, receipt in
            guard receipt != nil else { return }
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
        .onChange(of: viewModel.requestedInput) { _, input in
            handleRequestedInputChange(input)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
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
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
    }

    private var presentedContent: some View {
        mediaPickerContent
        .sheet(isPresented: $showsRoutePicker) {
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
        .sheet(isPresented: $showsVoice, onDismiss: {
            Task { await voiceSession.cancel() }
        }) {
            QuickCaptureVoiceView(session: voiceSession)
        }
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

    private var composer: some View {
        MarkdownComposerTextView(
            text: $viewModel.draft.text,
            selection: $composerSelection,
            isFocused: $composerIsFocused,
            controller: composerController
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brutal.bg.opacity(0.96))
        .overlay(alignment: .center) {
            if viewModel.draft.text.isEmpty && viewModel.draft.additionalPayloads.isEmpty {
                Text("Capture your ideas, tasks, links, and files…")
                    .font(Brutal.body())
                    .foregroundStyle(Brutal.faint)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 28)
                    .accessibilityHidden(true)
            }
        }
    }

    private var emptyDestinationBanner: some View {
        NavigationLink {
            CaptureDestinationLibraryView(viewModel: viewModel)
        } label: {
            Label("Choose a local Markdown destination to begin", systemImage: "folder.badge.plus")
                .font(Brutal.caption())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .foregroundStyle(Brutal.text)
        .background(Brutal.surface)
    }

    private var routeRow: some View {
        HStack(spacing: 8) {
            Button {
                composerController.dismissKeyboard()
                showsRoutePicker = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "tray.full")
                    Text(routeLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .accessibilityLabel("Capture destination \(routeLabel)")

            Menu {
                Button("Destination Default") { viewModel.setPlacementOverride(nil) }
                Button("Top") { viewModel.setPlacementOverride(.prepend) }
                Button("Bottom") { viewModel.setPlacementOverride(.append) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: placementIcon)
                    Text(viewModel.effectivePlacementLabel)
                }
            }
            .accessibilityLabel("Insertion position \(viewModel.effectivePlacementLabel)")

            Spacer(minLength: 4)

            if viewModel.draft.relativeNotePathOverride != nil
                || viewModel.draft.placementOverride != nil
                || viewModel.draft.entryTemplateID != nil {
                Button {
                    viewModel.clearRouteOverrides()
                } label: {
                    Image(systemName: "xmark.circle")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Reset capture route overrides")
            }
        }
        .font(Brutal.caption())
        .foregroundStyle(Brutal.muted)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Brutal.bg)
    }

    private var primaryActionRow: some View {
        HStack(spacing: 10) {
            Menu {
                Button { showsSketch = true } label: { Label("Sketch", systemImage: "pencil.tip") }
                Button { showsCamera = true } label: { Label("Camera", systemImage: "camera") }
                Button { showsPhotoPicker = true } label: { Label("Photo", systemImage: "photo") }
                Button { showsScreenshotPicker = true } label: {
                    Label("Screenshot", systemImage: "rectangle.inset.filled.and.person.filled")
                }
                Divider()
                Button { showsLinkPrompt = true } label: { Label("Web Link", systemImage: "link") }
            } label: {
                primaryIcon("Add media", systemImage: "photo")
            }

            Button { showsFileImporter = true } label: {
                primaryIcon("Add files", systemImage: "paperclip")
            }

            Button {
                Task { await viewModel.submit() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSubmitting {
                        ProgressView().tint(Brutal.bg)
                    }
                    Text(viewModel.isSubmitting ? "SENDING" : "SEND")
                }
                .font(Brutal.label())
                .foregroundStyle(Brutal.bg)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Brutal.text)
            }
            .disabled(!viewModel.canSubmit)
            .opacity(viewModel.canSubmit ? 1 : 0.35)
            .accessibilityIdentifier("quick_capture_submit")
            .accessibilityLabel(viewModel.isSubmitting ? "Sending capture" : "Send capture")

            Button { showsScanner = VNDocumentCameraViewController.isSupported } label: {
                primaryIcon("Scan document", systemImage: "doc.viewfinder")
            }
            .disabled(!VNDocumentCameraViewController.isSupported)

            Button {
                composerController.dismissKeyboard()
                showsVoice = true
            } label: {
                primaryIcon("Voice recording", systemImage: "waveform.badge.mic")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Brutal.bg)
        .disabled(isProcessingMedia)
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
                    .font(Brutal.caption())
                    .foregroundStyle(Brutal.text)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Brutal.surface)
                    .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Brutal.bg)
        .accessibilityLabel("Capture attachments")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brutal.error)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(Brutal.caption())
                    .foregroundStyle(Brutal.text)
                if viewModel.failedInboxCount > 0 {
                    Button("Retry queued captures") {
                        Task { await viewModel.retryFailedInbox() }
                    }
                    .font(Brutal.caption())
                }
            }
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(Brutal.surface2)
        .overlay(Rectangle().stroke(Brutal.error, lineWidth: 1))
    }

    private func primaryIcon(_ label: String, systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Brutal.text)
            .frame(width: 44, height: 48)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    private var routeLabel: String {
        if let override = viewModel.draft.relativeNotePathOverride {
            return URL(fileURLWithPath: override).deletingPathExtension().lastPathComponent
        }
        return viewModel.selectedDestination?.name ?? String(localized: "Choose destination")
    }

    private var placementIcon: String {
        switch viewModel.draft.placementOverride ?? viewModel.selectedDestination?.placement {
        case .prepend: return "text.line.first.and.arrowtriangle.forward"
        case .append: return "text.line.last.and.arrowtriangle.forward"
        case .beneathHeading: return "text.badge.plus"
        case nil: return "text.append"
        }
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
            composerController.dismissKeyboard()
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

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        // Permission prompts make the scene temporarily inactive. Keep explicit
        // one-shot requests alive until the app actually backgrounds.
        guard phase == .background else { return }
        locationRequestTask?.cancel()
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Finish Quick Capture voice"
        )
        Task {
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            await voiceSession.handleAppBackgrounding()
            await viewModel.saveDraftNow()
        }
    }

    private func handleCaptureDisappear() {
        locationRequestTask?.cancel()
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

    private func focusComposer() {
        composerIsFocused = true
        DispatchQueue.main.async { composerController.focus() }
    }

    private func loadAndPresentRequestedInput() async {
        await viewModel.load()
        if let input = viewModel.requestedInput {
            presentRequestedInput(input)
            viewModel.requestedInput = nil
        } else {
            try? await Task.sleep(for: .milliseconds(180))
            focusComposer()
        }
    }

    private func presentRequestedInput(_ input: CaptureRequestedInput) {
        composerController.dismissKeyboard()
        switch input {
        case .photos: showsPhotoPicker = true
        case .screenshots: showsScreenshotPicker = true
        case .camera: showsCamera = true
        case .files: showsFileImporter = true
        case .scan: showsScanner = VNDocumentCameraViewController.isSupported
        case .sketch: showsSketch = true
        case .link: showsLinkPrompt = true
        case .voice: showsVoice = true
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

    private func handleFileImport(_ result: Result<[URL], Error>) {
        Task {
            isProcessingMedia = true
            defer {
                isProcessingMedia = false
                focusComposer()
            }
            do {
                let urls = try result.get()
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
